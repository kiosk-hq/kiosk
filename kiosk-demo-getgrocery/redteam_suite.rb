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
# catalog prices, and sum correctly. Three local scenarios attack exactly that.
#
# Scenarios (13 BLOCKED, 3 SKIPPED):
#   BLOCKED : CrossTenantRead, ForgedUserId, UnpaidGatedAction, SpentResourceReuse,
#             PayForOtherUseSelf, MandatePrincipalSwap, MandateReplay, TokenTampering,
#             PrivilegeSelfSelection, WrongCurrencyCart, TamperedPriceCart,
#             InflatedTotalCart, RegistrationWithoutPow
#   SKIPPED : MissingKyc, ExpiredKyc, ForgedKyc (no KYC)
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby redteam_suite.rb

require "kiosk/redteam"
require "securerandom"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3005")
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

  # result_id_key: create_order response body["value"]["order_id"]
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
    catalog = catalog_resp.body.is_a?(Hash) ? (catalog_resp.body["rows"] || []) : []
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

    order_id    = order_resp.body.dig("value", "order_id")
    total_cents = order_resp.body.dig("value", "total_cents").to_i
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
    catalog_resp = client.query(_principal_b, name: "catalog")
    catalog = catalog_resp.body.is_a?(Hash) ? (catalog_resp.body["rows"] || []) : []
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
