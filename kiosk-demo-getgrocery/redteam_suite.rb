# frozen_string_literal: true

# getgrocery redteam battery (P6 corrected surface)
#
# Surface: catalog, delivery_slots, my_orders / create_order, schedule_delivery
# per_user_query : "my_orders"
# forge_action   : "create_order"
# gated_action   : "schedule_delivery" (ownership + payment mandate)
# requires_kyc   : false
# pow_difficulty : 0
#
# Scenarios (8 BLOCKED, 3 SKIPPED, RegistrationWithoutPow not run):
#   BLOCKED : CrossTenantRead, ForgedUserId, UnpaidGatedAction, SpentResourceReuse,
#             PayForOtherUseSelf, MandatePrincipalSwap, MandateReplay, TokenTampering
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
  pow_difficulty: 0,
  requires_kyc:   false,
  per_user_query: "my_orders",

  # result_id_key: create_order response body["value"]["order_id"]
  # row_id_key:    my_orders rows have "id" field
  result_id_key: "order_id",
  row_id_key:    "id",

  # create_owned: query catalog → pick first in-stock product → create_order
  # Returns { id: order_id, total_cents: N } (id key used by CrossTenantRead etc.)
  create_owned: ->(client, principal) {
    catalog_resp = client.query(principal, name: "catalog")
    catalog = catalog_resp.body.is_a?(Hash) ? (catalog_resp.body["rows"] || []) : []
    raise "redteam: catalog returned empty" if catalog.empty?
    product = catalog.first

    order_resp = client.run(
      principal,
      name:  "create_order",
      items: [{ sku: product["sku"], qty: 1 }],
    )
    raise "redteam: create_order failed (#{order_resp.status}): #{order_resp.body.inspect}" \
      unless order_resp.status == 200

    order_id    = order_resp.body.dig("value", "order_id")
    total_cents = order_resp.body.dig("value", "total_cents").to_i
    raise "redteam: create_order missing order_id" unless order_id

    { id: order_id, total_cents: total_cents }
  },

  # forge_args: returns base args for create_order (user_id injected by ForgedUserId scenario)
  forge_action: "create_order",
  forge_args: ->(client, _principal_a, _principal_b) {
    # We need a valid sku; query catalog as B to get one.
    # We use a fresh unauthenticated catalog query approach: just hardcode a minimal
    # args hash. The scenario will add user_id: a.user_id on top.
    # Actually: the ForgedUserId scenario registers A and B, and calls forge_args(client, a, b).
    # We can query catalog as B to get a valid sku.
    catalog_resp = client.query(_principal_b, name: "catalog")
    catalog = catalog_resp.body.is_a?(Hash) ? (catalog_resp.body["rows"] || []) : []
    raise "redteam: catalog empty for forge_args" if catalog.empty?
    product = catalog.first
    { items: [{ sku: product["sku"], qty: 1 }] }
  },

  # gated_action: schedule_delivery (requires ownership + payment mandate)
  gated_action: "schedule_delivery",
  gated_args:   ->(owned_ref) {
    {
      order_id:         owned_ref[:id],
      delivery_slot_id: 1,
      delivery_address: "1 Redteam St, Neo-Tokyo",
    }
  },

  # pay_for: build RS256 intent + cart mandates referencing order_id.
  # No card-setup step: this suite runs with KIOSK_TEST_AUTOCARD=1 against
  # stripe-mock, so the adapter auto-provisions a test card at capture and the
  # off_session charge settles. The gates under test are pure Kiosk logic.
  pay_for: ->(_client, principal, owned_ref) {
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
      line_items:         [{ order_id: owned_ref[:id], total: total_cents }],
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
  # Not applicable — must SKIP (no KYC)
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
  # Note: RegistrationWithoutPow is NOT run (pow_difficulty: 0)
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
