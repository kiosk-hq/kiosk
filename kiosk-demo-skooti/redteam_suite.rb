# frozen_string_literal: true

# skooti redteam battery
#
# Exercises the full skooti chain: Equihash PoW n=96 k=5 → reserve → pay →
# start_rental (2-gate ownership/payment; licence-free scooters are NOT KYC-gated,
# K-442).  Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's reservation, B tries start_rental
#   C3  SpentResourceReuse  — re-start_rental on an active reservation
#       KYC verifier variants — expired / forged attestation rejected at /kyc
#   MotorcycleForgedKyc      — a forged attestation self-asserting
#                              {age_over_18, licence_a} is rejected, so the
#                              KYC-attribute-gated rent_motorcycle stays 403.
#   IssuedKycJwsTheft        — a REAL issuer-signed jws minted for victim B via
#                              the stub-issuer approve page cannot be replayed by
#                              attacker A (KycVerifier binds sub to the caller),
#                              so A's rent_motorcycle stays 403 (K-440/K-443).
#
# Three local cashier-check beats attack ValidatingRentalProvider (the monetary
# check run at capture, before StubPsp settles):
#   WrongCurrencyCart  — pay own reservation in usd → 403
#   TamperedPriceCart  — pay below the operator's quoted rental price → 403
#   InflatedTotalCart  — cart total ≠ sum of its line items → 403
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
  requires_kyc:   true,   # skooti has a KYC verifier — rent_motorcycle is attribute-gated and ExpiredKyc/ForgedKyc exercise /kyc; start_rental itself is NOT KYC-gated (K-442)

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
      line_items:         [{ sku: owned_ref[:code], qty: 1, price_cents: total_cents, reservation_id: owned_ref[:id] }],
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

# ── Local scenarios: the cashier check (ValidatingRentalProvider) ─────────────
# The generic battery proves ownership/KYC/payment gates; these three prove the
# operator counts what lands on the counter — currency, single reservation,
# total. Each uses the AGENT'S OWN reservation (no cross-ownership, no KYC
# needed — the cashier check is monetary and runs at capture): an own-reservation
# cart at the wrong price/currency isolates the cashier check cleanly.

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

# A total below the operator's quoted per-minute rental price must be caught
# even though the mandate chain is internally consistent.
class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose total is below the operator's quoted rental price must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-price-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    # Pay 50c less than quoted, keeping the priced line consistent with the
    # lowered total so ONLY the quoted-total check can reject it.
    quoted        = owned[:price_per_min_cents].to_i
    quoted        = 100 if quoted <= 0
    lowered_total = quoted - 50
    m[:cart] = m[:cart].merge(
      line_items:         [{ sku: owned[:code], qty: 1, price_cents: lowered_total, reservation_id: owned[:id] }],
      total_amount_cents: lowered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "below-quote total settled (HTTP #{resp.status})")
  end
end

# Correct priced line but an inflated total (still within the intent cap,
# payment mirrors the cart) must be caught by the line-sum consistency check.
class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its line items must be rejected at capture",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-total-a", profile:)
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    # pay_for's single priced line sums to total_cents; inflate the total only.
    quoted = owned[:price_per_min_cents].to_i
    quoted = 100 if quoted <= 0
    m[:cart] = m[:cart].merge(total_amount_cents: quoted + 50)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    verdict_from(resp, detail: "total above the line-item sum settled (HTTP #{resp.status})")
  end
end

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# 12 generic + 3 local cashier-check beats; skooti's full surface makes all
# generic scenarios applicable (0 skips expected).
# RegistrationWithoutPow: pow_difficulty>0 (Equihash gate on) → always applicable.

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,     # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,     # C3
  # MissingKyc removed (K-442): start_rental (scooter) is no longer KYC-gated,
  # so "no KYC -> gated action blocked" no longer holds for it. The motorcycle's
  # missing-KYC block is covered by MotorcycleForgedKyc + kyc_flow A1.
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
  WrongCurrencyCart.new,                                 # cashier check — currency
  TamperedPriceCart.new,                                 # cashier check — below quote
  InflatedTotalCart.new,                                 # cashier check — total ≠ line sum
]

# ── Expected-applicable assertion ─────────────────────────────────────────────
#
# skooti exposes the full surface: 12 generic scenarios, 0 skips expected.
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

# ── skooti-local beat: forged motorcycle KYC attributes ───────────────
#
# The generic ForgedKyc scenario above proves a forged attestation is rejected
# at /kyc (the KYC verifier). This beat proves the SAME defence
# holds for the NAMED-ATTRIBUTE gate on rent_motorcycle: an attestation that
# SELF-ASSERTS {age_over_18, licence_a} but is signed by the WRONG key must be
# rejected at /kyc → the attributes are never granted → rent_motorcycle stays
# 403 kyc_required. A weakened signature check (e.g. alg:none) would let the
# agent mint its own licence and unlock a combustion motorcycle — a real BREACH.
motorcycle_forged_kyc = lambda do
  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)
  a = client.register!(name: "redteam-mc-fkyc", pow_difficulty: 20)

  # Reserve + pay for the motorcycle so ONLY the KYC-attribute gate can be the
  # thing that blocks (isolates Gate 0, exactly like the demo:kyc happy path).
  fleet = client.query(a, name: "scooters_available")
  mc    = (fleet.body["rows"] || []).find { |r| r["code"] == "MC-001" }
  raise "redteam(skooti): MC-001 not in fleet" unless mc

  rsv = client.run(a, name: "reserve", scooter_code: "MC-001")
  raise "redteam(skooti): reserve MC-001 failed (#{rsv.status})" unless rsv.status == 200
  reservation_id = rsv.body.dig("value", "reservation_id")
  price_min      = rsv.body.dig("value", "price_per_min_cents").to_i

  now = Time.now.to_i
  intent_id = SecureRandom.uuid
  cart_id   = SecureRandom.uuid
  total     = price_min.positive? ? price_min : 100
  intent = { id: intent_id, user_id: a.user_id, agent_id: a.agent_id, iss: ISSUER,
             scope: "mobility", cap_amount_cents: total + 100, currency: "eur",
             exp: now + 600, iat: now }
  cart = { id: cart_id, intent_mandate_id: intent_id, user_id: a.user_id, agent_id: a.agent_id,
           iss: ISSUER, line_items: [{ sku: "MC-001", qty: 1, reservation_id: }],
           total_amount_cents: total, currency: "eur", exp: now + 600, iat: now }
  pay_resp = client.pay(a, intent:, cart:)
  raise "redteam(skooti): pay MC-001 failed (#{pay_resp.status})" unless pay_resp.status == 200

  # Forge a KYC attestation that self-asserts BOTH attributes but is signed by
  # the WRONG key (trusted issuer, bad signature) — mirrors attest_forged.
  forged = JWT.encode(
    { sub: a.user_id, level: "verified", iss: "https://kyc.example",
      iat: now, exp: now + 3600,
      attributes: { age_over_18: true, licence_a: true } },
    FORGED_KYC_KEY, "RS256",
  )
  kyc_resp = client.kyc(a, attestation_jws: forged)

  # Whether or not /kyc rejected it, the decisive property is that
  # rent_motorcycle is STILL denied — the forged attributes were never granted.
  rent = client.run(a, name: "rent_motorcycle", reservation_id:)

  kyc_blocked  = Kiosk::Redteam.blocked?(kyc_resp)
  rent_blocked = rent.status == 403 && rent.body.is_a?(Hash) && rent.body.dig("error", "code") == "kyc_required"

  if kyc_blocked && rent_blocked
    { blocked: true, detail: "forged attestation rejected at /kyc (#{kyc_resp.status}); rent_motorcycle stays 403 kyc_required" }
  elsif rent_blocked
    # /kyc accepted it but no attributes were granted → still safe, still BLOCKED.
    { blocked: true, detail: "forged attestation not granted; rent_motorcycle stays 403 kyc_required" }
  else
    { blocked: false, detail: "forged KYC unlocked the motorcycle: /kyc=#{kyc_resp.status}, rent_motorcycle=#{rent.status}" }
  end
end

mc_beat = motorcycle_forged_kyc.call

# ── skooti-local beat: issued-jws cannot be stolen across agents ──────
#
# The stub issuer (K-440/K-443) signs an attestation for the request's OWN
# user_id. This beat proves an ISSUED, VALID jws cannot be lifted onto a
# DIFFERENT agent: victim B opens request_kyc, the human approves B's page (the
# page is intentionally open — the token is the credential), so B receives a
# real issuer-signed jws bound to B's user_id. Attacker A — which has reserved +
# paid for its OWN motorcycle so ONLY the KYC-attribute gate can block — submits
# B's jws to /agents/kyc. The KycVerifier binds `sub` to the authenticated
# identity, so it rejects (subject mismatch) → A's attributes are never granted
# → A's rent_motorcycle stays 403 kyc_required. A bug that dropped the sub check
# would let any agent replay someone else's licence — a real BREACH.
kyc_jws_theft = lambda do
  http_post_form = lambda do |path, form|
    uri = URI("#{BASE_URL}#{path}")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
    req.body = URI.encode_www_form(form)
    res = Net::HTTP.new(uri.host, uri.port).request(req)
    res.code.to_i
  end

  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)

  # Victim B obtains a REAL issuer-signed attestation via the human-approve page.
  b = client.register!(name: "redteam-kyc-victim-b", pow_difficulty: 20)
  req_b = client.run(b, name: "request_kyc")
  raise "redteam(skooti): request_kyc(B) failed (#{req_b.status})" unless req_b.status == 200
  token_b = req_b.body.dig("value", "request_id")
  approve_rc = http_post_form.call("/kyc/verify", { request: token_b, decision: "approve" })
  raise "redteam(skooti): approve(B) page failed (#{approve_rc})" unless approve_rc == 200

  status_b = client.query(b, name: "kyc_status", request_id: token_b)
  victim_jws = (status_b.body["rows"] || []).first&.dig("kyc_jws")
  raise "redteam(skooti): kyc_status(B) returned no jws" if victim_jws.nil? || victim_jws.empty?

  # Attacker A reserves + pays its OWN motorcycle so ONLY the KYC gate can block.
  a = client.register!(name: "redteam-kyc-attacker-a", pow_difficulty: 20)
  fleet = client.query(a, name: "scooters_available")
  mc    = (fleet.body["rows"] || []).find { |r| r["code"] == "MC-001" }
  raise "redteam(skooti): MC-001 not in fleet (theft beat)" unless mc

  rsv = client.run(a, name: "reserve", scooter_code: "MC-001")
  raise "redteam(skooti): reserve MC-001(A) failed (#{rsv.status})" unless rsv.status == 200
  reservation_id = rsv.body.dig("value", "reservation_id")
  price_min      = rsv.body.dig("value", "price_per_min_cents").to_i

  now = Time.now.to_i
  intent_id = SecureRandom.uuid
  cart_id   = SecureRandom.uuid
  total     = price_min.positive? ? price_min : 100
  intent = { id: intent_id, user_id: a.user_id, agent_id: a.agent_id, iss: ISSUER,
             scope: "mobility", cap_amount_cents: total + 100, currency: "eur",
             exp: now + 600, iat: now }
  cart = { id: cart_id, intent_mandate_id: intent_id, user_id: a.user_id, agent_id: a.agent_id,
           iss: ISSUER, line_items: [{ sku: "MC-001", qty: 1, reservation_id: }],
           total_amount_cents: total, currency: "eur", exp: now + 600, iat: now }
  pay_resp = client.pay(a, intent:, cart:)
  raise "redteam(skooti): pay MC-001(A) failed (#{pay_resp.status})" unless pay_resp.status == 200

  # A submits B's issued jws — the subject-binding must reject it.
  kyc_resp = client.kyc(a, attestation_jws: victim_jws)
  rent     = client.run(a, name: "rent_motorcycle", reservation_id:)

  kyc_blocked  = Kiosk::Redteam.blocked?(kyc_resp)
  rent_blocked = rent.status == 403 && rent.body.is_a?(Hash) && rent.body.dig("error", "code") == "kyc_required"

  if kyc_blocked && rent_blocked
    { blocked: true, detail: "B's issued jws rejected for A at /kyc (#{kyc_resp.status}); A's rent_motorcycle stays 403 kyc_required" }
  elsif rent_blocked
    { blocked: true, detail: "B's issued jws not granted to A; rent_motorcycle stays 403 kyc_required" }
  else
    { blocked: false, detail: "stolen jws unlocked A's motorcycle: /kyc=#{kyc_resp.status}, rent_motorcycle=#{rent.status}" }
  end
end

theft_beat = kyc_jws_theft.call

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

# ── skooti-local beat verdicts ────────────────────────────────────────
if mc_beat[:blocked]
  puts "  BLOCKED  ✓ MotorcycleForgedKyc — #{mc_beat[:detail]}"
else
  puts "  BREACH   ✗ MotorcycleForgedKyc — #{mc_beat[:detail]}"
end
if theft_beat[:blocked]
  puts "  BLOCKED  ✓ IssuedKycJwsTheft — #{theft_beat[:detail]}"
else
  puts "  BREACH   ✗ IssuedKycJwsTheft — #{theft_beat[:detail]}"
end

local_beats_blocked = (mc_beat[:blocked] ? 1 : 0) + (theft_beat[:blocked] ? 1 : 0)
blocked_count = blocked_results.size + local_beats_blocked
beat_breach   = (mc_beat[:blocked] ? 0 : 1) + (theft_beat[:blocked] ? 0 : 1)

puts ""
if breach_results.empty? && skipped_results.empty? && beat_breach.zero?
  puts "  #{blocked_count} BLOCKED, 0 SKIPPED, 0 BREACH — all attacks blocked."
else
  puts "  #{blocked_count} BLOCKED, #{skipped_results.size} SKIPPED, #{breach_results.size + beat_breach} BREACH"
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

exit 1 if breach_results.any? || beat_breach.positive?
