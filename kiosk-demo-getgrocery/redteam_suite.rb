# frozen_string_literal: true

# getgrocery redteam battery (R3 Phase 2 Task 4)
#
# Drives all generic Kiosk::Redteam scenarios against the live getgrocery
# server and asserts each applicable attack is BLOCKED.  Scenarios that
# require a surface getgrocery does not expose (gated_action, KYC,
# pow_difficulty > 0) are SKIPPED cleanly.
#
# getgrocery surface:
#   per_user_query : "my_orders"
#   create_owned   : browse stores → products_by_store → add_to_cart → confirm_delivery
#   forge_action   : "add_to_cart"
#   pay_for        : intent + cart mandates (grocery scope, RS256)
#   gated_action   : nil  (no unlock gate — cart ownership is NOT a payment gate)
#   requires_kyc   : false
#
# Note: RegistrationWithoutPow is NOT included here. getgrocery has
# pow_difficulty: 0 (no registration PoW gate).
#
# Usage (from kiosk-demo-getgrocery/):
#   SERVER_URL=http://127.0.0.1:3005 KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "securerandom"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3005")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 0,       # getgrocery has no registration PoW gate
  requires_kyc:   false,
  per_user_query: "my_orders",

  # result_id_key: add_to_cart response body["value"]["cart_id"]
  # row_id_key:    my_orders rows use "id" (delivery id)
  #
  # ForgedUserId: add_to_cart returns {cart_id:, cart_item_id:}, so
  # result_id_key="cart_id" extracts the cart_id.  Since my_orders only lists
  # deliveries (not carts), the check is always vacuously BLOCKED; the real
  # cart-ownership mutation check is in isolation_flow.rb.
  row_id_key:    "id",
  result_id_key: "cart_id",

  # Browse FreshMart store → find an in-stock product → add_to_cart →
  # confirm_delivery to create a deliveries row.
  # Returns { id: delivery_id, cart_id:, total_cents: }.
  create_owned: ->(client, principal) {
    # Browse stores
    stores_resp = client.query(principal, name: "stores")
    stores = stores_resp.body.is_a?(Hash) ? (stores_resp.body["rows"] || []) : []
    raise "redteam: no stores returned" if stores.empty?
    store    = stores.first
    store_id = store["id"]

    # Browse products
    prods_resp = client.query(principal, name: "products_by_store", store_id: store_id)
    prods = prods_resp.body.is_a?(Hash) ? (prods_resp.body["rows"] || []) : []
    raise "redteam: no products returned for store #{store_id}" if prods.empty?
    product = prods.find { |p| p["stock"].to_i > 0 } || prods.first

    # Add to cart
    add_resp = client.run(
      principal,
      name:       "add_to_cart",
      store_id:   store_id,
      product_id: product["id"],
      qty:        1,
    )
    raise "redteam: add_to_cart failed (#{add_resp.status}): #{add_resp.body.inspect}" \
      unless add_resp.status == 200

    cart_id = add_resp.body.dig("value", "cart_id")
    raise "redteam: cart_id missing from add_to_cart response" unless cart_id

    total_cents = product["price_cents"].to_i

    # Confirm delivery to create a deliveries row (so CrossTenantRead checks
    # that B's my_orders does not contain A's delivery_id, which is meaningful)
    confirm_resp = client.run(
      principal,
      name:             "confirm_delivery",
      cart_id:          cart_id,
      delivery_slot_id: 1,
      delivery_address: "1 Redteam St, Istanbul",
    )
    raise "redteam: confirm_delivery failed (#{confirm_resp.status}): #{confirm_resp.body.inspect}" \
      unless confirm_resp.status == 200

    delivery_id = confirm_resp.body.dig("value", "delivery_id")
    raise "redteam: delivery_id missing from confirm_delivery response" unless delivery_id

    {
      id:          delivery_id,   # CrossTenantRead uses this; must match row_id_key in my_orders
      cart_id:     cart_id,
      total_cents: total_cents,
    }
  },

  # ForgedUserId: B calls add_to_cart with user_id: A.user_id injected.
  # The server must ignore the caller-supplied user_id and use the GUC identity.
  forge_action: "add_to_cart",
  forge_args:   ->(client, principal_a, _principal_b) {
    stores_resp = client.query(principal_a, name: "stores")
    stores = stores_resp.body.is_a?(Hash) ? (stores_resp.body["rows"] || []) : []
    raise "redteam: no stores returned in forge_args" if stores.empty?
    store_id = stores.first["id"]

    prods_resp = client.query(principal_a, name: "products_by_store", store_id: store_id)
    prods = prods_resp.body.is_a?(Hash) ? (prods_resp.body["rows"] || []) : []
    raise "redteam: no products returned in forge_args for store #{store_id}" if prods.empty?
    product = prods.find { |p| p["stock"].to_i > 0 } || prods.first

    {
      store_id:   store_id,
      product_id: product["id"],
      qty:        1,
    }
  },

  # No gated_action: getgrocery's cart ownership is a mutation gate (not pay+KYC).
  # Scenarios UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf SKIP.
  gated_action: nil,
  gated_args:   nil,

  # MandatePrincipalSwap and MandateReplay: build the RS256 mandate payloads.
  # Returns { intent: Hash, cart: Hash } (raw payloads; the Client signs them).
  pay_for: ->(client, principal, owned_ref) {
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    total_cents      = owned_ref[:total_cents].to_i
    cap_amount_cents = total_cents + 100

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
      line_items:         [{ delivery_id: owned_ref[:id], total: total_cents }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  # No KYC in getgrocery — MissingKyc, ExpiredKyc, ForgedKyc SKIP.
  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

# ── Scenarios ─────────────────────────────────────────────────────────────────
#
# Applicable (5): CrossTenantRead, ForgedUserId, MandatePrincipalSwap,
#                 MandateReplay, TokenTampering.
# Skip (6):       UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf
#                 (no gated_action), MissingKyc, ExpiredKyc, ForgedKyc (no KYC).
# RegistrationWithoutPow: always skipped (pow_difficulty: 0).

scenarios = [
  # Applicable — must be BLOCKED
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  # Not applicable — must SKIP (no gated_action)
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,
  # Not applicable — must SKIP (no KYC)
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
  # Note: RegistrationWithoutPow is NOT included here. getgrocery has
  # pow_difficulty: 0 (no registration PoW gate).
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# Exactly 6 scenarios skip because getgrocery lacks gated_action + KYC.
# If this set changes, a profile typo may have disabled an applicable scenario.
EXPECTED_SKIP_NAMES = %w[
  UnpaidGatedAction
  SpentResourceReuse
  PayForOtherUseSelf
  MissingKyc
  ExpiredKyc
  ForgedKyc
].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── getgrocery redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: 0"
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
