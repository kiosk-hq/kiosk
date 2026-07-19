# frozen_string_literal: true

# hoteling redteam battery
#
# Exercises the hoteling chain: no PoW → no KYC → reserve_room → pay →
# confirm_booking (2-gate: ownership / payment). Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's booking, B tries confirm_booking
#   C3  SpentResourceReuse  — re-confirm an already-confirmed booking
#
# KYC scenarios and RegistrationWithoutPow are SKIPPED (hoteling has neither).
#
# Usage (from kiosk-demo-hoteling/):
#   SERVER_URL=http://127.0.0.1:3004 KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "jwt"
require "securerandom"
require "date"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3004")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# Dates far enough in the future to avoid conflicts with existing data.
# Each redteam run starts with a clean DB (demo:setup), so these are stable.
CHECK_IN  = (Date.today + 30).to_s.freeze
CHECK_OUT = (Date.today + 33).to_s.freeze
NIGHTS    = 3

# Helper: iterate all properties to find first available room for CHECK_IN..CHECK_OUT.
# Multiple scenarios run sequentially against the same DB; earlier scenarios may
# exhaust room types at one property, so we iterate until availability is found.
find_available = lambda { |client, principal|
  props_resp = client.query(principal, name: "properties")
  all_props  = props_resp.body.is_a?(Hash) ? (props_resp.body["rows"] || []) : []
  raise "redteam(hoteling): no properties in catalog" if all_props.empty?

  all_props.each do |p|
    avail_resp = client.query(principal, name: "availability",
      property_id: p["id"], check_in: CHECK_IN, check_out: CHECK_OUT)
    avail_rows = avail_resp.body.is_a?(Hash) ? (avail_resp.body["rows"] || []) : []
    next if avail_rows.empty?

    return { prop: p, room: avail_rows.first }
  end

  raise "redteam(hoteling): no room available at any property for #{CHECK_IN}..#{CHECK_OUT} " \
        "(#{all_props.size} properties checked)"
}

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 0,      # hoteling has no PoW gate at /register
  requires_kyc:   false,  # no KYC gate

  # ── per-user query — CrossTenantRead ─────────────────────────────────────
  per_user_query: "my_bookings",

  # ── row_id_key / result_id_key ────────────────────────────────────────────
  # Query rows (my_bookings) use "id" as the primary-key column.
  # The reserve_room action response uses "booking_id" in body["value"].
  row_id_key:    "id",
  result_id_key: "booking_id",

  # ── create_owned ─────────────────────────────────────────────────────────
  # Browse properties → check availability → reserve_room.
  # Iterates all properties to avoid exhausting a single property's room types.
  # Returns { id: booking_id, code: room_type_name, total_cents:, nights: }.
  create_owned: lambda { |client, principal|
    found = find_available.call(client, principal)
    prop  = found[:prop]
    room  = found[:room]

    rsv_resp = client.run(principal, name: "reserve_room",
      property_id:  prop["id"],
      room_type_id: room["id"],
      check_in:     CHECK_IN,
      check_out:    CHECK_OUT)
    raise "redteam(hoteling): reserve_room failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    booking_id  = rsv_resp.body.dig("value", "booking_id")
    total_cents = rsv_resp.body.dig("value", "total_cents").to_i

    {
      id:          booking_id,
      code:        room["name"],
      total_cents: total_cents,
      nights:      NIGHTS,
    }
  },

  # ── forge_action / forge_args — ForgedUserId ─────────────────────────────
  # B calls reserve_room with user_id: A.user_id injected. The server must
  # derive the owning user from the GUC (kiosk.current_user_id()), not args.
  forge_action: "reserve_room",
  forge_args:   lambda { |client, principal_a, _principal_b|
    found = find_available.call(client, principal_a)
    prop  = found[:prop]
    room  = found[:room]

    {
      property_id:  prop["id"],
      room_type_id: room["id"],
      check_in:     CHECK_IN,
      check_out:    CHECK_OUT,
    }
  },

  # ── gated_action / gated_args — UnpaidGatedAction, C2, C3 ───────────────
  gated_action: "confirm_booking",
  gated_args:   ->(ref) { { booking_id: ref[:id] } },

  # ── pay_for — MandatePrincipalSwap, MandateReplay, C2, C3 ───────────────
  # Shape mirrors hoteling_flow.rb: scope=lodging, line_items with
  # sku + qty + booking_id as required by Gate-2 of confirm_booking.
  pay_for: lambda { |_client, principal, owned_ref|
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    total_cents      = owned_ref[:total_cents].to_i
    cap_amount_cents = total_cents + 100
    nights           = owned_ref[:nights].to_i.nonzero? || NIGHTS

    intent = {
      id:               intent_id,
      user_id:          principal.user_id,
      agent_id:         principal.agent_id,
      iss:              ISSUER,
      scope:            "lodging",
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
      line_items:         [{ sku: owned_ref[:code], qty: nights, booking_id: owned_ref[:id] }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  # No KYC — hoteling does not require identity verification
  kyc_valid:   nil,
  kyc_expired: nil,
  kyc_forged:  nil,
)

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# All 13 are listed; 4 are expected to be skipped (KYC variants + PoW).
# 9 scenarios are applicable to hoteling's surface.

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,      # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,      # C3 — re-confirm
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
  Kiosk::Redteam::Scenarios::MissingKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,              # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::ForgedKyc.new,               # → SKIP (no KYC)
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new,  # → SKIP (no PoW)
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# hoteling has no KYC and no registration PoW — these 4 are expected to be
# skipped. If this set changes, a profile key was silently set to nil,
# disabling a gate scenario that should be applicable.
EXPECTED_SKIP_NAMES = %w[
  ExpiredKyc
  ForgedKyc
  MissingKyc
  RegistrationWithoutPow
].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── hoteling redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  pow_difficulty: 0 (none)"
puts "  requires_kyc:   false"
puts "  scenarios:      #{scenarios.size} (#{EXPECTED_SKIP_NAMES.size} expected skips)"
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
  puts "  #{blocked_results.size} BLOCKED, #{skipped_results.size} SKIPPED, #{breach_results.size} BREACH"
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
