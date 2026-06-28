# frozen_string_literal: true

# getgrocery redteam battery (R3 Phase 2 Task 4)
#
# Drives all generic Kiosk::Redteam scenarios against the live getgrocery
# server and asserts each applicable attack is BLOCKED.  Scenarios that
# require a surface getgrocery does not expose (forge_action, gated_action,
# KYC, pow_difficulty > 0) are SKIPPED cleanly.
#
# getgrocery surface:
#   per_user_query : "my_orders"
#   create_owned   : browse stores → products_by_store → add_to_cart → confirm_delivery
#   forge_action   : nil  (see note below — ForgedUserId SKIPPED; coverage in demo:isolation)
#   pay_for        : intent + cart mandates (grocery scope, RS256)
#   gated_action   : nil  (no unlock gate — cart ownership is NOT a payment gate)
#   requires_kyc   : false
#
# Note on ForgedUserId: add_to_cart returns a cart_id, but per_user_query
# ("my_orders") lists delivery ids — different entities.  The readback check
# in ForgedUserId would therefore be vacuously BLOCKED regardless of server
# behaviour.  forge_action is set to nil so ForgedUserId SKIPS honestly.
# The real forged-user_id coverage is in demo:isolation Assertion 7: a DB
# SELECT confirms the cart's user_id is the caller's (B's), not A's.
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

  # result_id_key / row_id_key: used by CrossTenantRead (delivery entities).
  # add_to_cart returns cart_id; my_orders lists delivery ids — different
  # entities, so ForgedUserId is SKIPPED (forge_action: nil) rather than
  # reporting a vacuous BLOCKED.  Coverage lives in demo:isolation Assertion 7.
  row_id_key:    "id",
  result_id_key: "id",

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

  # ForgedUserId SKIPPED: forge_action is nil so the scenario hits its
  # skip_verdict("no forge_action") guard.  The real coverage lives in
  # demo:isolation Assertion 7 (DB SELECT confirms cart belongs to B, not A).
  forge_action: nil,
  forge_args:   nil,

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
# Applicable (4): CrossTenantRead, MandatePrincipalSwap, MandateReplay,
#                 TokenTampering.
# Skip (7):       ForgedUserId (forge_action nil — vacuous entity mismatch;
#                   real coverage in demo:isolation Assertion 7),
#                 UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf
#                   (no gated_action), MissingKyc, ExpiredKyc, ForgedKyc (no KYC).
# RegistrationWithoutPow: always skipped (pow_difficulty: 0).

scenarios = [
  # Applicable — must be BLOCKED
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  # Not applicable — must SKIP (forge_action nil: add_to_cart returns cart_id
  # but my_orders lists delivery ids; readback would be vacuously BLOCKED.
  # Genuine forged-user_id coverage: demo:isolation Assertion 7, DB ownership check.)
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
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
# Exactly 7 scenarios skip: ForgedUserId (entity mismatch — vacuous readback,
# real coverage in demo:isolation Assertion 7) + no gated_action (3) + no KYC (3).
# If this set changes, a profile key may have been accidentally set to nil,
# disabling an applicable scenario.
EXPECTED_SKIP_NAMES = %w[
  ForgedUserId
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
