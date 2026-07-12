# frozen_string_literal: true

# foodelivery redteam battery (R3 Phase 2 Task 3)
#
# Drives all generic Kiosk::Redteam scenarios against the live foodelivery
# server and asserts each applicable attack is BLOCKED.  Scenarios that
# require a surface foodelivery does not expose (gated_action, KYC,
# pow_difficulty > 0) are SKIPPED cleanly.
#
# foodelivery surface:
#   per_user_query : "my_orders"
#   create_owned   : browse menu_by_restaurant → place_order
#   forge_action   : "place_order"
#   pay_for        : intent + cart mandates (food scope, RS256)
#   gated_action   : nil  (no unlock gate)
#   requires_kyc   : false
#
# Note: exec-time PoW (KIOSK_POW_DEMO) is a different gate from registration
# PoW; RegistrationWithoutPow only applies when /register requires PoW, which
# foodelivery does not (pow_difficulty: 0).  Exec-time-PoW-aware redteam is
# a future enhancement.
#
# Usage (from kiosk-demo-foodelivery/):
#   SERVER_URL=http://127.0.0.1:3002 KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "securerandom"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3002")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 0,       # foodelivery has no registration PoW gate
  requires_kyc:   false,
  per_user_query: "my_orders",

  # result_id_key: place_order response body["value"]["order_id"]
  # row_id_key:    my_orders rows use "id"
  row_id_key:    "id",
  result_id_key: "order_id",

  # Browse Mamma Pizza's menu for the margherita, then place_order.
  # Returns { id: order_id, menu_item_id:, total_cents: }.
  create_owned: ->(client, principal) {
    menu_resp  = client.query(principal, name: "menu_by_restaurant", restaurant: "Mamma Pizza")
    rows       = menu_resp.body.is_a?(Hash) ? (menu_resp.body["rows"] || []) : []
    margherita = rows.find { |r| r["sku"] == "margherita" }
    raise "redteam: margherita not found in menu_by_restaurant (rows=#{rows.inspect})" unless margherita

    order_resp = client.run(
      principal,
      name:             "place_order",
      menu_item_id:     margherita["id"],
      quantity:         1,
      delivery_address: "1 Redteam St, Istanbul",
    )
    raise "redteam: place_order failed (#{order_resp.status}): #{order_resp.body.inspect}" \
      unless order_resp.status == 200

    {
      id:           order_resp.body.dig("value", "order_id"),
      menu_item_id: margherita["id"],
      total_cents:  order_resp.body.dig("value", "total_cents"),
    }
  },

  # ForgedUserId: B calls place_order with user_id: A.user_id injected.
  # The server must ignore the caller-supplied user_id and use the GUC identity.
  forge_action: "place_order",
  forge_args:   ->(client, principal_a, _principal_b) {
    menu_resp  = client.query(principal_a, name: "menu_by_restaurant", restaurant: "Mamma Pizza")
    rows       = menu_resp.body.is_a?(Hash) ? (menu_resp.body["rows"] || []) : []
    margherita = rows.find { |r| r["sku"] == "margherita" }
    raise "redteam: margherita not found in forge_args (rows=#{rows.inspect})" unless margherita

    {
      menu_item_id:     margherita["id"],
      quantity:         1,
      delivery_address: "2 Forged St, Istanbul",
    }
  },

  # No gated_action: foodelivery's place_order is not behind a pay+KYC gate.
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
      scope:            "food",
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
      line_items:         [{ sku: "margherita", qty: 1 }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  # No KYC in foodelivery — MissingKyc, ExpiredKyc, ForgedKyc SKIP.
  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

# ── Scenarios ─────────────────────────────────────────────────────────────────
#
# Applicable (6): CrossTenantRead, ForgedUserId, MandatePrincipalSwap,
#                 MandateReplay, TokenTampering, PrivilegeSelfSelection.
# Skip (6):       UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf
#                 (no gated_action), MissingKyc, ExpiredKyc, ForgedKyc (no KYC).
# RegistrationWithoutPow: always skipped (pow_difficulty: 0), and NOT listed below.
# 12 scenarios listed → 6 applicable (BLOCKED), 6 skipped.

scenarios = [
  # Applicable — must be BLOCKED
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  # Not applicable — must SKIP (no gated_action)
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,
  # Not applicable — must SKIP (no KYC)
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
  # Note: RegistrationWithoutPow is NOT included here.
  # foodelivery has pow_difficulty: 0 (no registration PoW gate), and the
  # KIOSK_POW_DEMO flag enables exec-time PoW (a different gate type) which
  # RegistrationWithoutPow does not test.  Exec-time-PoW redteam is a future
  # enhancement; skooti covers RegistrationWithoutPow via pow_difficulty: 20.
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# Exactly 6 scenarios skip because foodelivery lacks gated_action + KYC.
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

puts "\n── foodelivery redteam battery ──"
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
