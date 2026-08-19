# frozen_string_literal: true

# getgrocery redteam battery (P6 corrected surface)
#
# Surface: catalog, delivery_slots, my_orders / create_order, reschedule_delivery
# per_user_query : "my_orders"
# forge_action   : "create_order" (delivery slot + address required)
# gated_action   : "reschedule_delivery" (ownership + settled payment; one per order)
# requires_kyc   : false
# pow_difficulty : 1  (register PoW ON — registration_pow_count=1)
#
# Every capture runs the ValidatingPaymentProvider cashier check: the cart
# must be EUR, reference the payer's own unsettled order, mirror its items at
# catalog prices, and sum correctly. Three local scenarios attack exactly that,
# and a fourth (MalformedItemsCart) attacks the input shape create_order takes.
#
# THE 0.4 WIRE. A query is `GET /kiosk/<query-name>` with its arguments in the
# query string, an action is `POST /kiosk/<action-name>` with its arguments as
# the JSON body, and `POST /kiosk/{query,run}` no longer exist. A success body
# IS the result (a bare array from a non-paginating query, the action's own
# object from an action, the settlement object from `pay`), and an error is an
# RFC 9457 problem document whose branch point is the TOP-LEVEL `code`. Two of
# the scenarios below are only expressible after that cut — RetiredWire and
# MethodMismatch — and both are here because a wire surface that quietly
# survives a deletion, or lies about a resource that exists, is an attack
# surface.
#
# Scenarios (16 BLOCKED, 3 SKIPPED):
#   BLOCKED : CrossTenantRead, ForgedUserId, UnpaidGatedAction, SpentResourceReuse,
#             PayForOtherUseSelf, MandatePrincipalSwap, MandateReplay, TokenTampering,
#             PrivilegeSelfSelection, WrongCurrencyCart, TamperedPriceCart,
#             InflatedTotalCart, MalformedItemsCart, RetiredWire, MethodMismatch,
#             RegistrationWithoutPow
#   SKIPPED : MissingKyc, ExpiredKyc, ForgedKyc (no KYC)
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby script/redteam_suite.rb

require "kiosk/redteam"
require "net/http"
require "securerandom"
require "uri"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3001")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  # register PoW is ON (registration_pow_count=1): a positive difficulty makes
  # RegistrationWithoutPow RUN (a missing/bad register proof must be rejected).
  # The Client ignores the magnitude (PoW solving is driven by the server's 402
  # challenges); only "> 0" matters here.
  pow_difficulty: 1,
  requires_kyc:   false,
  per_user_query: "my_orders",

  # result_id_key: create_order's response body IS the order object, so the key
  #                is read straight off it — body["order_id"] (0.4: no envelope)
  # row_id_key:    my_orders rows carry an "order_id" field (K-482: matches the
  #                consumer param name so an assistant copies the same key)
  result_id_key: "order_id",
  row_id_key:    "order_id",

  # create_owned: query catalog → pick first in-stock product → create_order
  # (delivery slot + address are REQUIRED — delivery is part of the order).
  # Returns { id:, total_cents:, items: [{sku, qty, price_cents}] } — the items
  # are kept so pay_for can build a cart that MIRRORS the order at catalog
  # prices (the ValidatingPaymentProvider cashier check requires it).
  create_owned: ->(client, principal) {
    catalog_resp = client.query(principal, name: "catalog")
    # A non-paginating query answers a BARE ARRAY — there is no `rows` to unwrap.
    catalog = catalog_resp.body.is_a?(Array) ? catalog_resp.body : []
    raise "redteam: catalog returned empty" if catalog.empty?
    product = catalog.first

    order_resp = client.run(
      principal,
      name:             "create_order",
      items:            [{ sku: product["sku"], qty: 1 }],
      delivery_slot_id: 1,
      delivery_address: "1 Redteam St, Dublin 1",
    )
    raise "redteam: create_order failed (#{order_resp.status}): #{order_resp.body.inspect}" \
      unless order_resp.status == 200

    order_id    = order_resp.body["order_id"]
    total_cents = order_resp.body["total_cents"].to_i
    raise "redteam: create_order missing order_id" unless order_id

    {
      id:          order_id,
      total_cents: total_cents,
      items:       [{ sku: product["sku"], qty: 1, price_cents: product["price_cents"].to_i }],
    }
  },

  # forge_args: returns base args for create_order (user_id injected by ForgedUserId scenario)
  forge_action: "create_order",
  forge_args: ->(client, _principal_a, _principal_b) {
    # Query the catalog as B to get a valid sku for create_order; the
    # ForgedUserId scenario adds user_id: A's UUID on top of these args.
    #
    # WHAT THAT BEAT NOW PROVES. `create_order` publishes
    # `additionalProperties: false` and does not declare `user_id` — the
    # principal is not one of its inputs — and 0.4 validates `input_schema` on
    # every call, so the forged argument is REFUSED (400 bad_request naming it)
    # instead of being accepted and silently ignored. Stricter than 0.3, and the
    # ownership half is still proved: nothing B creates ever appears under A.
    catalog_resp = client.query(_principal_b, name: "catalog")
    catalog = catalog_resp.body.is_a?(Array) ? catalog_resp.body : []
    raise "redteam: catalog empty for forge_args" if catalog.empty?
    product = catalog.first
    {
      items:            [{ sku: product["sku"], qty: 1 }],
      delivery_slot_id: 1,
      delivery_address: "1 Redteam St, Dublin 1",
    }
  },

  # gated_action: reschedule_delivery (ownership + settled payment; ONE
  # reschedule per order — the second attempt is the C3 spent-resource beat).
  gated_action: "reschedule_delivery",
  gated_args:   ->(owned_ref) {
    {
      order_id:         owned_ref[:id],
      delivery_slot_id: 2,
    }
  },

  # pay_for: build RS256 intent + cart mandates referencing order_id, with
  # item lines MIRRORING the order at catalog prices (cashier check).
  # No card-setup step: this suite runs with KIOSK_TEST_AUTOCARD=1 against
  # stripe-mock, so the adapter auto-provisions a test card at capture and the
  # off_session charge settles. The gates under test are pure Kiosk logic.
  pay_for: ->(_client, principal, owned_ref) {
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    total_cents      = owned_ref[:total_cents].to_i
    cap_amount_cents = total_cents + 200

    intent = {
      id:               intent_id,
      user_id:          principal.user_id,
      agent_id:         principal.agent_id,
      iss:              ISSUER,
      scope:            "grocery",
      cap_amount_cents: cap_amount_cents,
      currency:         "eur",
      exp:              now + 600,
      iat:              now,
    }

    cart = {
      id:                 cart_id,
      intent_mandate_id:  intent_id,
      user_id:            principal.user_id,
      agent_id:           principal.agent_id,
      iss:                ISSUER,
      line_items:         [{ order_id: owned_ref[:id] }] + (owned_ref[:items] || []),
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

# ── Local scenarios: the cashier check (ValidatingPaymentProvider) ────────────
# The generic battery proves ownership/payment gates; these three prove the
# operator counts what lands on the counter — currency, prices, total.

# A chain-consistent cart in the wrong currency must not settle: the engine
# only enforces intent/cart/payment agreement, the OPERATOR prices in EUR.
class WrongCurrencyCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "WrongCurrencyCart",
      category:    "payment",
      description: "A usd-denominated (chain-consistent) cart at a EUR operator must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-cur-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    m[:intent] = m[:intent].merge(currency: "usd")
    m[:cart]   = m[:cart].merge(currency: "usd")
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "usd cart settled at a EUR operator (HTTP #{resp.status})")
  end
end

# A tampered per-line price (with total and cap adjusted to stay
# chain-consistent) must be caught by the catalog-mirror check.
class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose line price differs from the catalog must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-price-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    tampered_items = (owned[:items] || []).map.with_index do |li, i|
      i.zero? ? li.merge(price_cents: li[:price_cents].to_i - 50) : li
    end
    tampered_total = tampered_items.sum { |li| li[:qty].to_i * li[:price_cents].to_i }
    m[:cart] = m[:cart].merge(
      line_items:         [{ order_id: owned[:id] }] + tampered_items,
      total_amount_cents: tampered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "below-catalog line price settled (HTTP #{resp.status})")
  end
end

# Correct lines but an inflated total (within the intent cap, payment mirrors
# the cart) must be caught by the sum check.
class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its lines must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-total-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    m[:cart] = m[:cart].merge(total_amount_cents: owned[:total_cents].to_i + 100)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "total above the order's catalog sum settled (HTTP #{resp.status})")
  end
end

# A cart of the wrong SHAPE is a client mistake and must come back as a typed
# 400, never as a 500 (K-693). The shipped guard was `items.empty?` under a
# message promising "a non-empty array": an emptiness check wearing a type
# check's words. `items` is not validated at the wire either
# (request_validation.rb: "ONLY the PoW proof(s) are validated"), so a String, a
# Hash, or an array of Strings each reached `.map` / `it[:sku]` and raised a raw
# NoMethodError or TypeError that executor.rb turned into ActionFailed — a 500
# on the flagship demo's headline action, the one the onboarding page is
# modelled on (which is how K-645 came to cite this handler as the CORRECT
# contrast it was not).
#
# Since 0.4 the FIRST of these refusals comes from the schema layer rather than
# from the handler: `input_schema` is validated on every call and `items`
# declares `{type: "array", minItems: 1, items: {…}}`, so a String, an Integer
# or an array of Strings is refused before {WireArguments.items} runs. The
# assertion is unchanged and still worth making — what it pins is that a
# mis-shaped cart is a TYPED 400 an assistant can act on, not which layer
# produced it, and the handler guard stays as the floor for shapes the schema
# admits.
#
# Asserts HTTP 400 AND a top-level `code == "bad_request"` AND no Ruby internals
# in the body: "not 200" would accept exactly the 500s at issue.
class MalformedItemsCart < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"
  RUBY_INTERNALS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion"].freeze

  # Each is a shape an assistant can plausibly send: the whole cart as one
  # object, a bare list of skus, a stringified cart, a count.
  BAD_ITEMS = [
    ["a String",             "sourdough-bread"],
    ["a Hash (one item, unwrapped)", { sku: "sourdough-bread", qty: 1 }],
    ["an array of Strings",  ["sourdough-bread"]],
    ["an array of Integers", [1, 2]],
    ["an Integer",           5],
    ["an array with null",   [nil]],
    ["an empty array",       []],
    ["absent",               nil],
  ].freeze

  def initialize
    super(
      name:        "MalformedItemsCart",
      category:    "input",
      description: "A non-array (or non-object-element) `items` must be a typed 400, never a 500",
    )
  end

  def call(client, profile)
    a        = register_principal(client, name: "redteam-items-a", profile:)
    failures = []
    statuses = []

    BAD_ITEMS.each do |label, items|
      args = { delivery_slot_id: 1, delivery_address: ADDRESS }
      args[:items] = items unless items.nil?
      resp = client.run(a, name: "create_order", **args)
      statuses << resp.status
      code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
      leak = RUBY_INTERNALS.find { |needle| JSON.generate(resp.body).include?(needle) }
      next if resp.status == 400 && code == "bad_request" && leak.nil?

      failures << "items #{label} → HTTP #{resp.status} code=#{code.inspect}#{leak ? " LEAKS #{leak.inspect}" : ""}"
    end

    # CONTROL — a well-formed cart must still place an order. Without it every
    # probe above would pass against a handler that rejected all input.
    catalog_body = client.query(a, name: "catalog").body
    catalog = catalog_body.is_a?(Array) ? catalog_body : []
    control = client.run(a, name: "create_order",
                            items: [{ sku: catalog.first["sku"], qty: 1 }],
                            delivery_slot_id: 1, delivery_address: ADDRESS)
    statuses << control.status
    unless control.status == 200
      failures << "CONTROL well-formed items → HTTP #{control.status} #{control.body.inspect} (want 200)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |s| s != 400 && s != 200 } || 400,
      detail:  failures.join(" | "),
    )
  end
end

# ── The cut itself: two scenarios only expressible after 0.4 ─────────────────
#
# Both dial raw paths, so they use Net::HTTP directly rather than the Client's
# verb helpers — the Client speaks REGISTERED verbs, and what is under test here
# is what happens at a path that is not one.

# A retired endpoint that still answers is a second conformance surface, and a
# second conformance surface is somewhere an attacker looks for the gate the
# first one has. T-074 = A was a HARD CUT: `POST /kiosk/query` and
# `POST /kiosk/run` now reach the per-verb controller as verbs literally named
# "query" and "run", which nobody registered, so they answer the ordinary 404 —
# no privileged endpoint left, no compatibility payload, no tombstone naming a
# replacement an attacker could probe.
class RetiredWire < Kiosk::Redteam::Scenario
  RETIRED = %w[query run].freeze

  def initialize
    super(
      name:        "RetiredWire",
      category:    "surface",
      description: "The deleted 0.3 multiplexed endpoints are GONE — an ordinary 404, not a tombstone",
    )
  end

  def call(client, profile)
    a       = register_principal(client, name: "redteam-retired-a", profile:)
    results = RETIRED.map do |name|
      uri = URI("#{BASE_URL}/kiosk/#{name}")
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json",
                                     "Authorization" => "Bearer #{a.token}")
      req.body = JSON.generate(name: "catalog")
      res  = Net::HTTP.new(uri.host, uri.port).request(req)
      body = (JSON.parse(res.body) rescue {})
      [res.code.to_i == 404 && body["code"] == "not_found",
       "POST /kiosk/#{name} → #{res.code}/#{body["code"].inspect}"]
    end

    Kiosk::Redteam::Verdict.new(
      blocked: results.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  results.all? { |ok, _| ok } ? "" :
                 "0.3 endpoints still answer: #{results.map(&:last).join(", ")} " \
                 "(want 404/\"not_found\")",
    )
  end
end

# A GET at an ACTION's path must be 405 with `Allow: POST`, never a silent 404.
# It matters that this is not a 404: the resource EXISTS, and an assistant that
# read 404 would conclude "this operator cannot do that" and abandon a verb it
# could have called correctly — a denial of service the operator inflicted on
# itself. RFC 9110 §15.5.6 already has the status; 0.4 added the matching
# `method_not_allowed` code so an assistant can branch on it.
class MethodMismatch < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "MethodMismatch",
      category:    "surface",
      description: "A GET at an action's path is 405 + Allow: POST, never a silent 404",
    )
  end

  def call(client, profile)
    a   = register_principal(client, name: "redteam-method-a", profile:)
    uri = URI("#{BASE_URL}/kiosk/create_order")
    res = Net::HTTP.new(uri.host, uri.port)
                   .request(Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{a.token}"))
    body    = (JSON.parse(res.body) rescue {})
    allow   = res["allow"].to_s
    blocked = res.code.to_i == 405 && body["code"] == "method_not_allowed" &&
              allow.upcase.include?("POST")

    Kiosk::Redteam::Verdict.new(
      blocked: blocked,
      skipped: false,
      status:  res.code.to_i,
      detail:  blocked ? "" :
                 "GET /kiosk/create_order → #{res.code}/#{body["code"].inspect} " \
                 "Allow=#{allow.inspect} (want 405/\"method_not_allowed\"/POST)",
    )
  end
end

# ── Scenarios ─────────────────────────────────────────────────────────────────

scenarios = [
  # Applicable — must be BLOCKED
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  WrongCurrencyCart.new,
  TamperedPriceCart.new,
  InflatedTotalCart.new,
  MalformedItemsCart.new,   # K-693 — a mis-shaped `items` is a typed 400, never a 500
  RetiredWire.new,          # T-074 = A — the 0.3 pair is deleted, not tombstoned
  MethodMismatch.new,       # 0.4 — a GET at an action is 405, never a silent 404
  # register PoW is ON — a missing/bad register proof must be rejected (runs
  # because pow_difficulty > 0).
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,
  # Not applicable — must SKIP (no KYC)
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── getgrocery redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW ON)"
puts "  requires_kyc:   false"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# ── Summary ───────────────────────────────────────────────────────────────────

blocked_results = results.select { |r| !r[:verdict].skipped && r[:verdict].blocked }
skipped_results = results.select { |r| r[:verdict].skipped }
breach_results  = runner.breaches

puts "\n── Summary ──"
blocked_results.each { |r| puts "  BLOCKED  ✓ #{r[:scenario].name}" }
skipped_results.each do |r|
  reason = r[:verdict].detail.delete_prefix("SKIP — ")
  puts "  SKIPPED  — #{r[:scenario].name} (#{reason})"
end
breach_results.each { |r| puts "  BREACH   ✗ #{r[:scenario].name} — #{r[:verdict].detail}" }

puts ""
if breach_results.empty?
  puts "  #{blocked_results.size} BLOCKED, #{skipped_results.size} SKIPPED, 0 BREACH — all attacks blocked."
else
  puts "  #{blocked_results.size} BLOCKED, #{skipped_results.size} SKIPPED, #{breach_results.size} BREACH — FIX REQUIRED"
end

# ── Expected-applicable check ─────────────────────────────────────────────────

actual_skip_names = skipped_results.map { |r| r[:scenario].name }.sort
expected_sorted   = EXPECTED_SKIP_NAMES.sort

if actual_skip_names != expected_sorted
  puts ""
  puts "  EXPECTED-APPLICABLE ASSERTION FAILED:"
  puts "    Expected skips: #{expected_sorted.inspect}"
  puts "    Actual skips:   #{actual_skip_names.inspect}"
  puts "  A profile key may have been set to nil, disabling a gate scenario."
  exit 2
end

exit 1 if breach_results.any?
