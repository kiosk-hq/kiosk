# frozen_string_literal: true

# getgrocery redteam battery (P6 corrected surface)
#
# Surface: catalog, delivery_slots, my_orders / create_order, reschedule_delivery
#
# THE PROFILE IS NOT MAPPED OUT HERE (K-1040 completing K-1037, the K-1035
# class). This block used to name the verb bound to each generic role —
# `per_user_query`, `forge_action`, `gated_action` — above a `requires_kyc` /
# `pow_difficulty` pair, all five hand-copied from the one `Profile.new` further
# down in this same file. `Profile.new` is now the single copy of all five: each
# binding is stated at the constructor, beside the note this map was compressing
# and beside the `*_args` lambda that shows what the verb actually takes, and
# the run header prints the gate posture live off the object every scenario
# reads. Nothing in the deleted map was FALSE — what it could not survive is a
# RENAME, which is precisely what K-710 has done to a hand-kept list in these
# suites twice already, and a stale map here would have a reader believe the
# battery attacks a verb it no longer names. Orientation is not the cost it
# looks like: six of the seven demo redteam suites carry no such map, hoteling
# and skooti included — the only other two that build a Profile at all — and
# they are read from the constructor exactly as this one now is.
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
# THE SCENARIO LIST IS NOT RE-TYPED HERE EITHER (K-1239) — the same repair the
# paragraph above records for the profile map (K-1040), for the same reason, in
# the same file. The rule is: every APPLICABLE scenario must be BLOCKED and the
# KYC trio must SKIP (no KYC here). The membership is `scenarios = [` further
# down, which is the single copy.
#
# This block used to enumerate the applicable ones by name, and it had already
# gone stale in precisely the way a hand-kept list does. The array registers
# `DeviceGrantRoleSelfSelection` — the shared, framework-side claim-ceremony
# beat every demo runs (K-072, K-1128), the ONE beat here that is not local to
# this suite — and the enumeration never learned of it, so the header advertised
# eighteen applicable attacks where the battery runs nineteen. NOTHING WENT RED,
# and that is the point: the run's totals are COMPUTED from the array, so no run
# ever disagreed with itself; only the comment was wrong, and only a reader was
# misled. K-1183 found the identical defect in philslist's README, the same beat
# omitted from the same kind of list, and repaired it by eliding the numeral; that
# it recurred here is why this list is DELETED rather than corrected.
#
# Read the membership off the array. Each entry there carries the finding it was
# written for, which is more than this list ever said, and `EXPECTED_SKIP_NAMES`
# beside it is what ASSERTS the applicable/skip split — so a silently disabled
# gate fails the run, where a stale comment could only mislead a reader.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby script/redteam_suite.rb

require "date"
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

  # ── declared_roles — DeviceGrantRoleSelfSelection ────────────────────────
  # `Kiosk.configuration.roles` for this origin (config/initializers/kiosk.rb).
  # The claim ceremony's beat must name a role this origin ACTUALLY declares:
  # an invented one was refused by the vulnerable code too, which is how a
  # green battery sat on top of K-072 for nineteen days. The scenario also
  # derives one off the wire, so a stale list here weakens the probe rather
  # than emptying it.
  declared_roles: %w[customer],
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

  # forge_args: returns base args for create_order — which needs a delivery slot
  #             and an in-zone address on top of its items (user_id injected by
  #             the ForgedUserId scenario, never declared here)
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

  # gated_action — gated on ownership + settled payment, and ONE reschedule per
  # order: the second attempt is the C3 spent-resource beat. (The verb is on the
  # line below and is not repeated here, K-1040.)
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
      # THE SCAN IS TOLD WHAT THIS PROBE SENT (T-121). {WireArguments.items}
      # names the element it rejected — `each item must be a {sku, qty} object
      # — got String ("sourdough-bread")` — so the bytes scanned for
      # RUBY_INTERNALS are partly the probe's own, and a cart whose sku spelled
      # `TypeError` would be reported as a BREACH on its own echo, under a
      # runner whose prose says a BREACH means "fix the app, not the scenario".
      scan = Kiosk::Redteam::LeakScan.scan(resp.body, RUBY_INTERNALS, supplied: args)
      next if resp.status == 400 && code == "bad_request" && !scan.leak?

      failures << "items #{label} → HTTP #{resp.status} code=#{code.inspect}" \
                  "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
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

# K-773 — THE STANDING HOSTILE-SHAPE BEAT.
#
# K-773 is the finding that Postgres used to do free shape-checking on wire
# arguments and ActiveRecord does not. getgrocery is the demo where it measured
# POSITIVE-PLUS-ONE: `order_id` was interpolated into a `::uuid` cast (class
# one, closed by {UuidCheck}), and `delivery_slot_id` / `qty` were read with a
# bare `.to_i` that `true`, `false`, an Array and an object all answer with
# NoMethodError — a `500 action_failed` for an argument the published
# `input_schema` already declares an integer (class two, closed by reading
# through `.to_s` first). The row's own bar for closing was that those hostile
# shapes be re-sent AS A STANDING BEAT rather than from the migration's
# throwaway harness, and this is that beat. {MalformedItemsCart} stands for the
# `items` CONTAINER (K-693) — a String, a bare Hash, an array of strings, `[]`,
# absent; this one takes the scalar arguments it does not, AND the `qty` INSIDE
# a well-formed element, which fell between the two beats until K-773's
# 2026-08-25 reopen named it: `qty` is half of class two above and
# `MalformedItemsCart` never varies an element's fields.
#
# WHAT IS PROBED, NAMED RATHER THAN CLAIMED. create_order: `items[].qty`,
# `delivery_slot_id`, `delivery_date`, `delivery_address`. reschedule_delivery:
# `order_id`. An argument not on that list is not covered here — extend the
# list, never widen the sentence.
#
# WHICH LAYER ANSWERS WHAT, measured rather than assumed. `delivery_slot_id`
# declares `type: "integer", minimum: 1, maximum: 6` and `order_id` declares
# `format: "uuid"`, so 0.4's `input_schema` validation refuses those shapes
# BEFORE the handler — for them this beat pins the CONTRACT (typed 400, no 5xx,
# no wrong answer served as 200) across both layers and goes red if either
# stops holding, e.g. if a descriptor widened the type or dropped
# `additionalProperties: false`.
#
# `delivery_date` AND `delivery_address` ARE DIFFERENT, and they are why this
# beat is not merely a schema test: both are declared as a bare
# `type: "string"`, because neither domain is expressible in JSON Schema — the
# delivery horizon rolls forward every midnight and the served zone is a list of
# Dublin districts. Every string reaches getgrocery's OWN guards, so
# `delivery_date: "nope"` is refused by {WireArguments.delivery_date} and an
# out-of-zone address by {WireArguments.served_zone}, and nothing but those
# guards stands behind either.
class HostileArgShapes < Kiosk::Redteam::Scenario
  ADDRESS = "2 Redteam Row, Dublin 2"

  # An error body must never carry the runtime's or the database's own
  # vocabulary: that is the same property {MalformedItemsCart} asserts, and
  # these probes are the ones most likely to reach a cast.
  LEAKS = ["NoMethodError", "TypeError", "undefined method", "no implicit conversion",
           "::uuid", "PG::", "22P02", "invalid input syntax", "ActiveRecord::"].freeze

  # The five families the row names.
  SHAPES = [true, false, [], {}, [1], { "a" => 1 }, "abc", 1.5].freeze

  def initialize
    super(
      name:        "HostileArgShapes",
      category:    "input",
      description: "Boolean/array/object/junk values on items[].qty, delivery_slot_id, delivery_date, delivery_address and order_id are a typed 400 — never a 500",
    )
  end

  def call(client, profile)
    a         = register_principal(client, name: "redteam-shapes-a", profile:)
    @failures = []
    catalog   = client.query(a, name: "catalog").body
    raise "redteam(getgrocery): empty catalog" unless catalog.is_a?(Array) && catalog.any?

    good_items = [{ sku: catalog.first["sku"], qty: 1 }]

    # ── schema-declared integers and uuids ──────────────────────────────────
    #
    # `delivery_slot_id`: BOTH LAYERS REFUSE ALL EIGHT SHAPES BELOW, and that
    # sentence is only true since K-1025 — the same defect as `qty`'s below, one
    # argument over. The guard read `raw.to_s.to_i`, and `"1.5".to_i` is 1,
    # which lands INSIDE the declared 1..6: `1.5` was the one shape the schema
    # alone refused, and without it in front the handler would have booked a
    # fractional slot as slot 1. It goes through the same
    # {WireArguments.whole_number} `qty` uses now, so `2.0` is still slot 2
    # (json_schemer accepts it) and `1.5` is a 400 from either layer. The
    # non-vacuity proof is K-1020's: drop `delivery_slot_id`'s declared type
    # from both verbs' `input_schema` and these stay 400.
    SHAPES.each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_address: ADDRESS),
              supplied: v
      refused "reschedule_delivery order_id=#{v.inspect}",
              client.run(a, name: "reschedule_delivery", order_id: v, delivery_slot_id: 1),
              supplied: v
    end
    # Out of the declared 1..6 range — the same refusal, from the schema's
    # `minimum`/`maximum` rather than its `type`.
    [0, -1, 7, 999].each do |v|
      refused "create_order delivery_slot_id=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: v, delivery_address: ADDRESS),
              supplied: v
    end

    # ── `qty`, INSIDE a well-formed items element ───────────────────────────
    #
    # The container is correct in every call here — one element, a real sku —
    # so the ONLY thing wrong is the element's own `qty`, which is class two of
    # K-773's finding: the guard used to be a bare `.to_i`, and `true`/`false`/
    # `[]`/`{}` have none, so each was a `500 action_failed` for a value
    # `input_schema` already declares `{type: "integer", minimum: 1}`.
    #
    # BOTH LAYERS REFUSE ALL TEN VALUES BELOW, and that sentence is only true
    # since K-1020. The guard K-773 left behind read `(item[:qty] || 1).to_s.to_i`
    # and it agreed with the schema on eight of them: `false` and `1.5` BOTH came
    # out of it as a legal quantity 1 — `||` reads `false` as absent, and
    # `"1.5".to_i` is 1 — so the schema alone was refusing those two while the
    # comment here claimed a second, independent refusal and named only one
    # exception. `wire_arguments.rb` now mirrors the schema's own `integer`
    # (whole numbers, `2.0` included, because json_schemer accepts that — measured),
    # so a 400 here is two refusals rather than one. The non-vacuity proof is
    # K-773's own mutation: drop `qty`'s declared type from `input_schema` and
    # these stay 400 instead of booking `false` and `1.5` as one unit.
    sku = catalog.first["sku"]
    (SHAPES + [0, -1]).each do |v|
      refused "create_order items[0].qty=#{v.inspect}",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # ── MAGNITUDE, the axis every probe above misses (K-1047) ───────────────
    #
    # Everything above varies `qty`'s TYPE, and `[0, -1]` sit just under the
    # declared `minimum: 1`. No probe anywhere in this fleet had ever sent an
    # integer LARGE enough to matter — which is exactly how a `500
    # action_failed` for a body the published descriptor calls VALID survived
    # three hostile-shape waves (K-773, K-1020, K-1025) in this very beat.
    #
    # TWO probes, because there are two bounded columns behind one argument and
    # they give way at different widths. Both numbers are DERIVED from the
    # catalogue row this run actually got, so a reseed at other prices cannot
    # quietly make either vacuous:
    #
    #   · UNPRICEABLE CART — `qty` is a legal `order_items.qty` (int4) and the
    #     cart still cannot be TOTALLED: `price_cents * qty` passes
    #     `orders.total_cents`, also int4. MEASURED on a booted origin before
    #     the fix, `qty: 30_000_000` of the 89-cent `milk-0.5l` →
    #     `ActiveModel::RangeError: 2670000000 is out of range …` out of
    #     `Order.insert!`, served as **HTTP 500 `action_failed`**. The refusal
    #     it must be instead comes from {WireArguments.priceable_total}, which
    #     is reached only once the prices are resolved — no schema can express
    #     a bound on a SUM of other rows' values.
    #   · UNSTORABLE QUANTITY — `qty` itself past int4, which IS expressible
    #     per-property and so is refused by the descriptor's own `maximum`
    #     before the handler runs at all.
    #
    # The non-vacuity proof is the K-773/K-1020 mutation, one bound at a time:
    # drop `maximum` from `qty` in `input_schema` and the second probe reaches
    # the handler; delete the `priceable_total` call from
    # {CreateOrderOperation} and the first goes back to 500.
    price = catalog.first["price_cents"].to_i
    raise "redteam(getgrocery): catalogue row has no price_cents" unless price.positive?

    max_int4 = 2_147_483_647
    { "unpriceable cart"     => (max_int4 / price) + 1,
      "unstorable qty"       => max_int4 + 1 }.each do |why, v|
      refused "create_order items[0].qty=#{v} (#{why}, K-1047)",
              client.run(a, name: "create_order", items: [{ sku: sku, qty: v }],
                            delivery_slot_id: 1, delivery_address: ADDRESS),
              supplied: { sku: sku, qty: v }
    end

    # ── the two bare strings, where getgrocery's OWN guards are the only
    # thing standing (see the header) ───────────────────────────────────────
    # NOT probed: `"[2026-09-01]"` and `"20260101"`. getgrocery's guard uses
    # `Date.parse` and NOT hoteling's stricter `Date.iso8601` deliberately —
    # `wire_arguments.rb` records that this verb pair has always scanned a date
    # out of a loose string, so accepting them is PUBLISHED behaviour and a
    # probe demanding a 400 would be asserting against the demo's own contract.
    # Measured, not assumed: `"[2026-09-01]"` answers 200 today.
    ["nope", "2026-13-45", "0000-01-01", "true"].each do |v|
      refused "create_order delivery_date=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items, delivery_slot_id: 1,
                            delivery_address: ADDRESS, delivery_date: v),
              supplied: v
    end
    ["", "   ", "1 Main St, Cork", "Dublin 99", "somewhere"].each do |v|
      refused "create_order delivery_address=#{v.inspect}",
              client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_address: v),
              supplied: v
    end

    # ── CONTROL ─────────────────────────────────────────────────────────────
    #
    # Without it every assertion above could pass vacuously on an origin that
    # refuses EVERYTHING. A well-formed order must still be placed.
    control = client.run(a, name: "create_order", items: good_items,
                            delivery_slot_id: 1, delivery_address: ADDRESS)
    unless control.status == 200
      @failures << "CONTROL well-formed create_order → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 90]} (want 200; the probes above prove nothing " \
                   "on an origin that refuses everything)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: @failures.empty?, skipped: false, status: 400,
      detail:  @failures.join(" | "),
    )
  end

  private

  # `supplied:` is what this probe put on the wire, and it is what stops the
  # leak assertion being decided by the attacker (T-121). getgrocery names the
  # value it got — `invalid delivery_date: nope`, `qty must be a whole number
  # >= 1 — got …` — so the bytes scanned for LEAKS are partly the probe's own,
  # and a `delivery_address` spelling `PG::` would otherwise be reported as a
  # BREACH on its own echo, under a runner whose prose says a BREACH means "fix
  # the app, not the scenario". The default is nil, which is the pre-fix oracle
  # exactly: forgetting to declare risks a FALSE BREACH, never a missed leak.
  def refused(label, resp, supplied: nil)
    doc  = resp.body.is_a?(Hash) ? resp.body : {}
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, LEAKS, supplied: supplied)
    return if resp.status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{resp.status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
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
# "query" and "run", which nobody registered, so they answer the ordinary 404 an
# AUTHENTICATED caller gets — no privileged endpoint left, no compatibility
# payload, no tombstone naming a replacement an attacker could probe.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above
# (K-1094). `VerbController#serve` resolves the identity BEFORE it looks the
# verb up, so a caller with no bearer never reaches the registry lookup that
# produces the 404 — it is answered 401 `unauthenticated`, exactly as it would
# be at any other name. Every retired-wire beat in the fleet dialled WITH a
# bearer, so seven suites' prose said the 404 flatly while nothing anywhere
# tested the anonymous case the sentence was wrong about.
class RetiredWire < Kiosk::Redteam::Scenario
  RETIRED = %w[query run].freeze

  def initialize
    super(
      name:        "RetiredWire",
      category:    "surface",
      description: "The deleted 0.3 multiplexed endpoints are GONE — the ordinary 404 an " \
                   "authenticated caller gets, 401 without a bearer, not a tombstone",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-retired-a", profile:)

    results = RETIRED.flat_map do |name|
      [[a.token, 404, "verb_not_found", ""], [nil, 401, "unauthenticated", " (anon)"]]
        .map do |token, want_status, want_code, tag|
        uri     = URI("#{BASE_URL}/kiosk/#{name}")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{token}" if token
        req = Net::HTTP::Post.new(uri, headers)
        req.body = JSON.generate(name: "catalog")
        res  = Net::HTTP.new(uri.host, uri.port).request(req)
        body = (JSON.parse(res.body) rescue {})
        [res.code.to_i == want_status && body["code"] == want_code,
         "POST /kiosk/#{name}#{tag} → #{res.code}/#{body["code"].inspect} " \
         "(want #{want_status}/#{want_code.inspect})"]
      end
    end

    Kiosk::Redteam::Verdict.new(
      blocked: results.all? { |ok, _| ok },
      skipped: false,
      status:  404,
      detail:  results.all? { |ok, _| ok } ? "" :
                 "a retired 0.3 endpoint answers the wrong thing: " \
                 "#{results.reject { |ok, _| ok }.map(&:last).join(", ")}",
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

# A `date` in the PAST on `delivery_slots` must be a typed 400 naming the
# earliest bookable day — not `200 []` (T-090, spec §9.1).
#
# WHY THE ADVERSARIAL BATTERY OWNS THIS. The empty list this replaces was not a
# missing check, it was an AMBIGUOUS ANSWER: `DeliverySlots.bookable_ids`
# rejects every window whose start has passed, and every window of a past day
# has, so a date thirty days back returned byte-identical bytes to TODAY once
# the last window has begun. One of those two is worth retrying tomorrow and
# the other never will be, and an assistant reading `[]` could not tell which
# it had. Two answers that cannot be told apart is the shape this battery
# exists to catch.
#
# The CONTROL is what makes the beat non-vacuous: a FUTURE date at the same
# in-zone address must still be ANSWERED, or a handler that refused every date
# would pass.
class PastDeliveryDate < Kiosk::Redteam::Scenario
  ADDRESS = "1 Redteam St, Dublin 1"

  def initialize
    super(
      name:        "PastDeliveryDate",
      category:    "surface",
      description: "A delivery date before today is a typed 400 on BOTH delivery_slots and create_order — never 200 [], never an order",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-pastdate-a", profile:)

    past   = (Date.today - 30).iso8601
    future = (Date.today + 7).iso8601

    bad = client.query(a, name: "delivery_slots", date: past, delivery_address: ADDRESS)
    ctl = client.query(a, name: "delivery_slots", date: future, delivery_address: ADDRESS)

    # The refusal must NAME the earliest bookable day, and that day is read in
    # the OPERATOR's locale (Europe/Dublin) — which is not necessarily the
    # runner's. So the assertion is "a calendar date is named", not a literal
    # equal to this machine's `Date.today`: pinning the runner's clock into the
    # expectation would make the beat fail across a timezone boundary for a
    # reason that has nothing to do with the behaviour under test.
    detail  = bad.body.is_a?(Hash) ? bad.body["detail"].to_s : ""
    named   = detail.include?("in the past") && detail.match?(/\d{4}-\d{2}-\d{2}/)
    refused = bad.status == 400 && error_code(bad) == "bad_request" && named
    control = ctl.status == 200 && ctl.body.is_a?(Array) && ctl.body.any?

    # ── THE WRITE HALF (K-969) ──────────────────────────────────────────────
    # The read side is the primary guarantee — an assistant must never SEE a
    # window it cannot book — but an assistant may name a date it never read
    # from a `delivery_slots` response, so the ORDER has to refuse it too. That
    # is the belt to this beat's braces, and it was already true here
    # ({WireArguments.delivery_date} refuses `date < Date.today`) while being
    # pinned only CONDITIONALLY: `getgrocery_flow.rb`'s K-480 probe asserts the
    # past-WINDOW guard and is a no-op before 08:00 Dublin. This half is
    # unconditional and is about the past DAY.
    sku      = (client.query(a, name: "catalog").body.then { |b| b.is_a?(Array) ? b : [] }).first&.dig("sku")
    order    = client.run(a, name: "create_order", items: [{ sku: sku, qty: 1 }],
                             delivery_slot_id: 1, delivery_address: ADDRESS, delivery_date: past)
    o_detail = order.body.is_a?(Hash) ? order.body["detail"].to_s : ""
    order_refused = order.status == 400 && error_code(order) == "bad_request" &&
                    o_detail.include?("in the past") && o_detail.match?(/\d{4}-\d{2}-\d{2}/)

    # CONTROL for the write half — the SAME cart at a future date must place an
    # order, so the refusal above cannot be an unrelated cart or address answer.
    order_ctl = client.run(a, name: "create_order", items: [{ sku: sku, qty: 1 }],
                              delivery_slot_id: 1, delivery_address: ADDRESS, delivery_date: future)
    order_control = order_ctl.status == 200 && order_ctl.body.is_a?(Hash) &&
                    !order_ctl.body["order_id"].to_s.empty?

    ok = refused && control && order_refused && order_control
    Kiosk::Redteam::Verdict.new(
      blocked: ok,
      skipped: false,
      status:  bad.status,
      detail:  ok ? "" :
                 "delivery_slots date=#{past} → #{bad.status}/#{error_code(bad).inspect} " \
                 "detail=#{detail[0, 120].inspect}; " \
                 "CONTROL date=#{future} → #{ctl.status}/#{ctl.body.is_a?(Array) ? ctl.body.size : 0} rows; " \
                 "create_order delivery_date=#{past} → #{order.status}/#{error_code(order).inspect} " \
                 "detail=#{o_detail[0, 120].inspect}; " \
                 "CONTROL create_order delivery_date=#{future} → #{order_ctl.status} " \
                 "(want 400 bad_request naming the earliest bookable date on BOTH, and both controls answered)",
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
  # The CLAIM-ceremony sibling of the line above: PrivilegeSelfSelection covers
  # `/auth/register`, where the role was never client-readable; this covers the
  # door that WAS open (K-072) — the unauthenticated `device_authorization`
  # request that opens the account-binding ceremony.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  WrongCurrencyCart.new,
  TamperedPriceCart.new,
  InflatedTotalCart.new,
  MalformedItemsCart.new,   # K-693 — a mis-shaped `items` is a typed 400, never a 500
  HostileArgShapes.new,     # K-773 — boolean/array/object/junk shapes on the other args → typed 400
  RetiredWire.new,          # T-074 = A — the 0.3 pair is deleted, not tombstoned
  MethodMismatch.new,       # 0.4 — a GET at an action is 405, never a silent 404
  PastDeliveryDate.new,     # T-090/K-969 — a past date is a named 400 on the read AND the write side
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
# K-1035 class — DERIVE BOTH, NEVER TYPE THEM.  `requires_kyc` was a typed
# `false` sitting directly under a line that already read `profile.pow_difficulty`
# off the object, so one flipped constructor argument 660 lines up left the banner
# announcing the opposite of the battery it introduces.  The ON/OFF gloss is
# derived for the same reason: `1 (register PoW ON)` and `0 (register PoW ON)`
# were both printable, and only one of them is ever true.
#
# These are the values every generic scenario reads to decide whether it is
# applicable — RegistrationWithoutPow skips on 0, the KYC trio skips on false —
# so the banner now says exactly what the run below will do.
puts "  pow_difficulty: #{profile.pow_difficulty} (register PoW #{profile.pow_difficulty.to_i > 0 ? "ON" : "OFF"})"
puts "  requires_kyc:   #{profile.requires_kyc}"
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
