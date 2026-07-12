# frozen_string_literal: true

# skooti redteam battery (R3 Phase 2 Task 4)
#
# Exercises the full skooti chain: Equihash PoW n=96 k=5 → KYC → reserve → pay →
# start_rental (3-gate ownership/KYC/payment).  Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's reservation, B tries start_rental
#   C3  SpentResourceReuse  — re-start_rental on an active reservation
#       KYC bypass variants  — missing / expired / forged attestation
#
# Usage (from kiosk-demo-skooti/):
#   SERVER_URL=http://127.0.0.1:3003 KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "jwt"
require "openssl"
require "securerandom"

# ── Load skooti's StubKyc from lib/ ──────────────────────────────────────────
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "stub_kyc"

BASE_URL = ENV.fetch("SERVER_URL", "http://127.0.0.1:3003")
ISSUER   = ENV.fetch("KIOSK_ISSUER", BASE_URL)

# ── KYC helpers (redteam-only) ────────────────────────────────────────────────
#
# Extend StubKyc with expired/forged variants directly in this file.
# stub_kyc.rb's real verification path is NOT changed (no gate-weakening).
#
# expired: signed with the REAL key but exp 1h in the past — specifically tests
#          the server's exp check, not just signature checking.
# forged:  signed with a DIFFERENT key but the TRUSTED issuer — tests signature
#          verification in isolation (a weakened-sig regression would be caught).
class StubKyc
  # Mint a JWS signed with the real key but with exp 1h in the past.
  def self.attest_expired(user_id:)
    now = Time.now.to_i
    JWT.encode(
      {
        sub:   user_id,
        level: "verified",
        iss:   "https://kyc.example",
        iat:   now - 7200,
        exp:   now - 3600,
      },
      KEYPAIR,   # private_constant accessible inside class body
      "RS256",
    )
  end
end

# Wrong signing key with the TRUSTED issuer — the only adversarial property is
# the bad signature.  Using the correct issuer ensures that if signature
# verification is weakened (e.g. alg:none attack), this scenario catches it.
FORGED_KYC_KEY = OpenSSL::PKey::RSA.generate(2048)

def attest_forged(user_id)
  now = Time.now.to_i
  JWT.encode(
    {
      sub:   user_id,
      level: "verified",
      iss:   "https://kyc.example",  # trusted issuer; ONLY the signature is wrong
      iat:   now,
      exp:   now + 3600,
    },
    FORGED_KYC_KEY,
    "RS256",
  )
end

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 20,     # >0 flips on the /register gate; skooti gates with an Equihash proof (n=96 k=5) and the client solves the real 402 challenge — the numeric value is not an Equihash param
  requires_kyc:   true,   # start_rental Gate-2 checks kyc_verified_at

  # ── per-user query — CrossTenantRead ─────────────────────────────────────
  per_user_query: "my_reservations",

  # ── row_id_key / result_id_key ────────────────────────────────────────────
  # Query rows (my_reservations) use "id" as the primary-key column.
  # The reserve action response uses "reservation_id" in body["value"].
  row_id_key:    "id",
  result_id_key: "reservation_id",

  # ── create_owned ─────────────────────────────────────────────────────────
  # Browse the available fleet and reserve the first scooter.
  # Returns { id: reservation_id, code: scooter_code, price_per_min_cents: }.
  # reserve needs no KYC — it only requires an authenticated agent token.
  create_owned: lambda { |client, principal|
    fleet_resp = client.query(principal, name: "scooters_available")
    rows       = fleet_resp.body.is_a?(Hash) ? (fleet_resp.body["rows"] || []) : []
    scooter    = rows.first
    raise "redteam(skooti): no available scooters in scooters_available" unless scooter

    rsv_resp = client.run(principal, name: "reserve", scooter_code: scooter["code"])
    raise "redteam(skooti): reserve failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    {
      id:                  rsv_resp.body.dig("value", "reservation_id"),
      code:                rsv_resp.body.dig("value", "scooter_code"),
      price_per_min_cents: rsv_resp.body.dig("value", "price_per_min_cents").to_i,
    }
  },

  # ── forge_action / forge_args — ForgedUserId ─────────────────────────────
  # B calls reserve with user_id: A.user_id injected.  The server must derive
  # the owning user from the GUC (kiosk.current_user_id()), not from args.
  forge_action: "reserve",
  forge_args:   lambda { |client, principal_a, _principal_b|
    fleet_resp = client.query(principal_a, name: "scooters_available")
    rows       = fleet_resp.body.is_a?(Hash) ? (fleet_resp.body["rows"] || []) : []
    scooter    = rows.first
    raise "redteam(skooti): no scooters for forge_args" unless scooter

    { scooter_code: scooter["code"] }
  },

  # ── gated_action / gated_args — UnpaidGatedAction, C2, C3, KYC ──────────
  gated_action: "start_rental",
  gated_args:   ->(ref) { { reservation_id: ref[:id] } },

  # ── pay_for — MandatePrincipalSwap, MandateReplay, C2, C3, KYC ──────────
  # Exact shapes from rental_flow.rb:166-214 (RS256, scope=mobility,
  # line_items with sku + reservation_id as required by Gate-3).
  pay_for: lambda { |_client, principal, owned_ref|
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    cart_id   = SecureRandom.uuid

    price_min        = owned_ref[:price_per_min_cents].to_i
    total_cents      = price_min > 0 ? price_min : 100
    cap_amount_cents = total_cents + 100

    intent = {
      id:               intent_id,
      user_id:          principal.user_id,
      agent_id:         principal.agent_id,
      iss:              ISSUER,
      scope:            "mobility",
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
      line_items:         [{ sku: owned_ref[:code], qty: 1, reservation_id: owned_ref[:id] }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  # ── KYC attestation variants ──────────────────────────────────────────────
  kyc_valid:   ->(user_id) { StubKyc.attest(user_id: user_id) },
  kyc_expired: ->(user_id) { StubKyc.attest_expired(user_id: user_id) },
  kyc_forged:  method(:attest_forged),
)

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# All 12 are listed; skooti's full surface makes all applicable.
# RegistrationWithoutPow: pow_difficulty>0 (Equihash gate on) → always applicable.

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,     # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,     # C3
  Kiosk::Redteam::Scenarios::MissingKyc.new,
  Kiosk::Redteam::Scenarios::ExpiredKyc.new,
  Kiosk::Redteam::Scenarios::ForgedKyc.new,
  Kiosk::Redteam::Scenarios::UnpaidGatedAction.new,
  Kiosk::Redteam::Scenarios::CrossTenantRead.new,
  Kiosk::Redteam::Scenarios::ForgedUserId.new,
  Kiosk::Redteam::Scenarios::RegistrationWithoutPow.new, # Equihash gate on → always applicable
  Kiosk::Redteam::Scenarios::MandatePrincipalSwap.new,
  Kiosk::Redteam::Scenarios::MandateReplay.new,
  Kiosk::Redteam::Scenarios::TokenTampering.new,
  Kiosk::Redteam::Scenarios::PrivilegeSelfSelection.new,
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# skooti exposes the full surface: 13 scenarios, 0 skips expected.
# If this set changes, a profile typo silently disabled a gate — fail loud.
EXPECTED_SKIP_NAMES = [].freeze

# ── Run ───────────────────────────────────────────────────────────────────────

puts "\n── skooti redteam battery ──"
puts "  base_url:       #{BASE_URL}"
puts "  register gate:  Equihash n=96 k=5 (pow_difficulty>0)"
puts "  requires_kyc:   true"
puts "  scenarios:      #{scenarios.size}"
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
if breach_results.empty? && skipped_results.empty?
  puts "  #{blocked_results.size} BLOCKED, 0 SKIPPED, 0 BREACH — all attacks blocked."
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
