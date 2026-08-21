# frozen_string_literal: true

# skooti redteam battery
#
# Exercises the full skooti chain: Equihash PoW n=96 k=5 → reserve → pay →
# start_rental (ownership/licence-free-vehicle/payment gates; licence-free
# scooters are NOT KYC-gated, K-442).  Headline scenarios:
#   C2  PayForOtherUseSelf  — B pays for A's reservation, B tries start_rental
#   C3  SpentResourceReuse  — re-start_rental on an active reservation
#       KYC verifier variants — expired / forged attestation rejected at /kyc
#   MotorcycleForgedKyc      — a forged attestation self-asserting
#                              {age_over_18, licence_a} is rejected, so the
#                              KYC-attribute-gated rent_motorcycle stays 403.
#   MotorcycleViaStartRental — the KYC gate cannot be walked around by VERB:
#                              reserve(MC-001) → pay → start_rental must be
#                              refused, not answered with an unlock token
#                              (K-687 — it was answered with one).
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
# Plus one input-shape beat:
#   MalformedUuidArg   — a junk reservation_id, as an arg AND inside a signed
#                        cart, is a typed 400 with no SQL internals — never a 500
#
# And two beats that are only expressible after the 0.4 cutover (T-074 = A):
#   RetiredWire        — POST /kiosk/query and POST /kiosk/run are an ordinary
#                        404 / not_found: the multiplexed pair was DELETED, so
#                        there is no privileged endpoint left, no compatibility
#                        payload, and no second conformance surface to attack.
#   MethodMismatch     — a GET at an action's path is 405 / method_not_allowed
#                        with `Allow: POST`, never a silent 404 an assistant
#                        would read as "this operator cannot do that".
#
# THE 0.4 WIRE, throughout: a query is `GET <endpoint>/<query-name>` with its
# arguments in the query string, an action is `POST <endpoint>/<action-name>`
# with its arguments as the JSON body, a success body IS the result, and an
# error is an RFC 9457 problem document whose branch point is the TOP-LEVEL
# `code` (`message` became `detail`).
#
# Usage (from kiosk-demo-skooti/):
#   SERVER_URL=http://127.0.0.1:3004 KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits non-zero if any applicable scenario reports a BREACH or if the
# expected skip set does not match (catches profile typos that disable gates).

require "kiosk/redteam"
require "jwt"
require "openssl"
require "securerandom"
require "net/http"
require "uri"
require "json"

# ── KYC helpers (redteam-only) — the KYC broker rewire ───────────────────
#
# skooti's self-hosted stub KYC issuer retired; the SHARED KYC broker is now
# the trusted issuer. Valid/expired attestations are minted with the broker's
# ProveKey (ProveTestIssuer, signing with the key skooti trusts); the forged
# variant signs with a DIFFERENT key but the TRUSTED issuer so signature
# verification is exercised in isolation (an alg:none/weakened-sig regression is
# caught). None of this weakens the real verification path.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "prove_test_issuer"
require_relative "../app/services/prove_trust"

BASE_URL   = ENV.fetch("SERVER_URL", "http://127.0.0.1:3004")
ISSUER     = ENV.fetch("KIOSK_ISSUER", BASE_URL)
# The broker's base URL (set by the two-server demo:redteam harness). The
# broker-flavored beats (theft / cross-operator / forged-callback) drive it.
BROKER_URL = ENV.fetch("KIOSK_PROVE_BROKER_URL", "http://127.0.0.1:3020")
TRUSTED_ISSUER = ProveTrust.issuer

# Wrong signing key with the TRUSTED issuer — the only adversarial property is
# the bad signature. Using the correct issuer ensures a weakened-sig regression
# (e.g. alg:none) is caught.
FORGED_KYC_KEY = OpenSSL::PKey::RSA.generate(2048)

def attest_forged(user_id)
  now = Time.now.to_i
  JWT.encode(
    {
      sub:   user_id,
      level: "verified",
      iss:   TRUSTED_ISSUER,  # trusted issuer; ONLY the signature is wrong
      aud:   ProveTrust.operator_id,  # correct audience — isolates the signature defect
      iat:   now,
      exp:   now + 3600,
    },
    FORGED_KYC_KEY,
    "RS256",
  )
end

# ── KYC broker driver (redteam-only) ─────────────────────────────────────
# Start a real verification at the broker and approve it as the human would, so
# the broker mints a REAL signed claim and POSTs it to skooti's callback. Used by
# the theft / cross-operator / forged-callback beats.

# The intake secret arrives in this driver's env (the rake task passes the
# broker wiring through — KIOSK_PROVE_INTAKE_SECRET, the operator side's one
# role-named variable, K-694); there is no shipped default anywhere any more
# (K-547/K-650).
def broker_start_verification(callback_url:, subject_handle:, requested_claims: %w[age_over_18 licence_category:A], operator_id: ProveTrust.operator_id, secret: ENV.fetch("KIOSK_PROVE_INTAKE_SECRET"))
  uri = URI("#{BROKER_URL}/verifications")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{secret}")
  req.body = JSON.generate(operator_id:, callback_url:, requested_claims:, subject_handle:)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def broker_approve(request_id)
  uri = URI("#{BROKER_URL}/verify")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
  req.body = URI.encode_www_form(request: request_id, decision: "approve")
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  res.code.to_i
end

def post_kyc_callback(body)
  uri = URI("#{BASE_URL}/kyc/callback")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  res.code.to_i
end

# ── Profile ───────────────────────────────────────────────────────────────────

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 20,     # >0 flips on the /register gate; skooti gates with an Equihash proof (n=96 k=5) and the client solves the real 402 challenge — the numeric value is not an Equihash param
  requires_kyc:   true,   # skooti has a KYC verifier — rent_motorcycle is attribute-gated and ExpiredKyc/ForgedKyc exercise /kyc; start_rental itself is NOT KYC-gated (K-442) because it only ever activates licence-free vehicles: since K-687 it REFUSES a needs_licence one instead of quietly unlocking it (MotorcycleViaStartRental)

  # ── per-user query — CrossTenantRead ─────────────────────────────────────
  per_user_query: "my_reservations",

  # ── row_id_key / result_id_key ────────────────────────────────────────────
  # Query rows (my_reservations) carry a "reservation_id" field — matching the
  # reserve action response's body["value"]["reservation_id"] and the
  # start_rental/rent_motorcycle param name, so an assistant copies the same
  # key with no guessing (K-482).
  row_id_key:    "reservation_id",
  result_id_key: "reservation_id",

  # ── create_owned ─────────────────────────────────────────────────────────
  # Browse the available fleet and reserve the first scooter.
  # Returns { id: reservation_id, code: scooter_code, price_per_min_cents: }.
  # reserve needs no KYC — it only requires an authenticated agent token.
  create_owned: lambda { |client, principal|
    fleet_resp = client.query(principal, name: "scooters_available")
    rows       = fleet_resp.body.is_a?(Array) ? fleet_resp.body : []
    scooter    = rows.first
    raise "redteam(skooti): no available scooters in scooters_available" unless scooter

    rsv_resp = client.run(principal, name: "reserve", scooter_code: scooter["code"])
    raise "redteam(skooti): reserve failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    {
      id:                  rsv_resp.body["reservation_id"],
      code:                rsv_resp.body["scooter_code"],
      price_per_min_cents: rsv_resp.body["price_per_min_cents"].to_i,
    }
  },

  # ── forge_action / forge_args — ForgedUserId ─────────────────────────────
  # B calls reserve with user_id: A.user_id injected. Since 0.4 the wire itself
  # REFUSES it: `reserve` publishes `additionalProperties: false` and declares
  # only `scooter_code`, so the injected principal is a typed 400 before the
  # handler runs. (Through 0.3 the argument was accepted and the handler derived
  # the owner from the GUC instead; the generic scenario accepts either — a 4xx
  # refusal, or a 200 whose row never surfaces under A.)
  forge_action: "reserve",
  forge_args:   lambda { |client, principal_a, _principal_b|
    fleet_resp = client.query(principal_a, name: "scooters_available")
    rows       = fleet_resp.body.is_a?(Array) ? fleet_resp.body : []
    scooter    = rows.first
    raise "redteam(skooti): no scooters for forge_args" unless scooter

    { scooter_code: scooter["code"] }
  },

  # ── gated_action / gated_args — UnpaidGatedAction, C2, C3, KYC ──────────
  gated_action: "start_rental",
  gated_args:   ->(ref) { { reservation_id: ref[:id] } },

  # ── pay_for — MandatePrincipalSwap, MandateReplay, C2, C3, KYC ──────────
  # Exact shapes from script/rental_flow.rb:166-214 (RS256, scope=mobility,
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
  # Valid/expired minted with the shared broker ProveKey (the key skooti now
  # trusts); forged signs with a wrong key under the trusted issuer.
  kyc_valid:   ->(user_id) { ProveTestIssuer.attest(user_id: user_id) },
  kyc_expired: ->(user_id) { ProveTestIssuer.attest_expired(user_id: user_id) },
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

# A malformed reservation_id must come back as a TYPED 400, never a 500
# (K-581/K-582). Three surfaces, one guard (UuidCheck): start_rental's and
# rent_motorcycle's `reservation_id` args, and the `{"reservation_id":…}`
# reference inside a signed cart mandate that the cashier prices at capture.
# Before the guard, Postgres raised InvalidTextRepresentation on the `::uuid`
# cast — not a Kiosk error, so it escaped as a raw 500 with the PG message
# attached, and on the PAY path a 500 is the worst possible answer because an
# assistant cannot tell it from "the charge may have gone through".
#
# Asserts three properties, not one: HTTP 400 (a client mistake reported as such),
# the problem document's top-level `code == "bad_request"` (typed, so an
# assistant can branch on it), and no SQL internals anywhere in the body. A
# generic `blocked?` verdict would accept a 403 or a 401 here, so this scenario
# builds its Verdict directly.
#
# Since 0.4 the arg-shaped probes are refused one layer EARLIER — `reservation_id`
# declares `format: "uuid"` and `input_schema` is validated on every call — so the
# refusal now comes from the declared contract rather than from UuidCheck inside
# the handler. Same status, same code, same no-leak property; the guard behind it
# still stands for anything that reaches it (the signed-cart probe below, which
# no input_schema covers).
#
# rent_motorcycle is probed too, and it is the interesting one: its KYC-attribute
# gate runs FIRST, so an un-KYC'd principal gets 403 kyc_required and the uuid
# guard is never reached. The scenario therefore submits a valid attestation
# before probing it — otherwise the assertion would pass without exercising the
# guard at all.
class MalformedUuidArg < Kiosk::Redteam::Scenario
  MALFORMED     = ["not-a-uuid", "1; DROP TABLE reservations", ""].freeze
  SQL_INTERNALS = ["::uuid", "PG::", "22P02", "invalid input syntax"].freeze

  def initialize
    super(
      name:        "MalformedUuidArg",
      category:    "input",
      description: "A malformed reservation_id — as a start_rental/rent_motorcycle arg AND inside a signed cart — must be a typed 400, never a 500",
    )
  end

  def call(client, profile)
    a = register_principal(client, name: "redteam-uuid-a", profile:)
    # Clear rent_motorcycle's Gate 0 so the uuid guard BEHIND it is reachable.
    # A plain `kyc_valid` attestation is not enough: Gate 0 tests the NAMED
    # attributes, so without them every probe would come back 403 kyc_required
    # and this scenario would pass while exercising nothing.
    kyc = client.kyc(a, attestation_jws: ProveTestIssuer.attest(
      user_id: a.user_id, attributes: { age_over_18: true, licence_a: true },
    ))
    raise "redteam(skooti): MalformedUuidArg fixture broken — /kyc returned #{kyc.status}" unless kyc.status == 200

    failures = []
    statuses = []

    MALFORMED.each do |junk|
      check(failures, statuses, "start_rental(#{junk.inspect})",
            client.run(a, name: "start_rental", reservation_id: junk))
      check(failures, statuses, "rent_motorcycle(#{junk.inspect})",
            client.run(a, name: "rent_motorcycle", reservation_id: junk))
      check(failures, statuses, "pay cart reservation_id=#{junk.inspect}",
            pay_with_ref(client, a, junk))
    end

    # CONTROL — without it the pay assertion above could pass vacuously: any 400
    # `bad_request` raised EARLIER in the pay pipeline (mandate chain, scope,
    # amounts) would satisfy it without the cashier ever being reached. A
    # WELL-FORMED but nonexistent reservation_id must therefore come back as the
    # cashier's own "reservation not found" 403 — proving the request really does
    # get that far, and that the shape check is not swallowing the authz answer.
    control = pay_with_ref(client, a, "00000000-0000-4000-8000-000000000000")
    unless control.status == 403
      failures << "CONTROL well-formed-but-unknown reservation_id → HTTP #{control.status} " \
                  "(want the cashier's 403; a 400 here means the malformed-uuid probes never reached the cashier)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: failures.empty?,
      skipped: false,
      status:  statuses.find { |s| s != 400 } || 400,
      detail:  failures.join(" | "),
    )
  end

  private

  def check(failures, statuses, label, resp)
    statuses << resp.status
    leak = SQL_INTERNALS.find { |needle| JSON.generate(resp.body).include?(needle) }
    code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
    return if resp.status == 400 && code == "bad_request" && leak.nil?

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}#{leak ? " LEAKS #{leak.inspect}" : ""}"
  end

  # Deliberately reserves NOTHING: the shape guard runs before the cashier takes
  # a connection, so a cart naming a junk reservation_id needs no reservation
  # behind it — and this scenario therefore takes no scooter out of the shared
  # fleet the other scenarios draw on.
  def pay_with_ref(client, principal, junk)
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    intent = { id: intent_id, user_id: principal.user_id, agent_id: principal.agent_id,
               iss: ISSUER, scope: "mobility", cap_amount_cents: 200, currency: "eur",
               exp: now + 600, iat: now }
    cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: principal.user_id,
             agent_id: principal.agent_id, iss: ISSUER,
             line_items: [{ sku: "any-scooter", qty: 1, price_cents: 100, reservation_id: junk }],
             total_amount_cents: 100, currency: "eur", exp: now + 600, iat: now }
    client.pay(principal, intent:, cart:)
  end
end

# ── Scenario list ─────────────────────────────────────────────────────────────
#
# 12 generic + 3 local cashier-check beats + the K-581/K-582 malformed-uuid
# beat; skooti's full surface makes all generic scenarios applicable (0 skips
# expected). Nine further skooti-local beats run after the runner, below —
# seven of them, plus the two 0.4-cutover beats (RetiredWire, MethodMismatch).
# RegistrationWithoutPow: pow_difficulty>0 (Equihash gate on) → always applicable.

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,     # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,     # C3
  # MissingKyc removed (K-442): start_rental (scooter) is no longer KYC-gated,
  # so "no KYC -> gated action blocked" no longer holds for it. The motorcycle's
  # missing-KYC block is covered by MotorcycleForgedKyc + kyc_flow A1 — and,
  # since K-687, by MotorcycleViaStartRental, which is the beat that would have
  # caught what removing MissingKyc left uncovered: this generic scenario drove
  # the profile's gated_action (start_rental) against whatever create_owned
  # reserved, i.e. always a SCOOTER, so no scenario ever pointed start_rental at
  # the motorcycle until that beat did.
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
  MalformedUuidArg.new,                                  # K-581/K-582 — junk uuid → typed 400, no 500
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
  mc    = Array(fleet.body).find { |r| r["code"] == "MC-001" }
  raise "redteam(skooti): MC-001 not in fleet" unless mc

  rsv = client.run(a, name: "reserve", scooter_code: "MC-001")
  raise "redteam(skooti): reserve MC-001 failed (#{rsv.status})" unless rsv.status == 200
  reservation_id = rsv.body["reservation_id"]
  price_min      = rsv.body["price_per_min_cents"].to_i

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
    { sub: a.user_id, level: "verified", iss: TRUSTED_ISSUER,
      aud: ProveTrust.operator_id, iat: now, exp: now + 3600,
      attributes: { age_over_18: true, licence_a: true } },
    FORGED_KYC_KEY, "RS256",
  )
  kyc_resp = client.kyc(a, attestation_jws: forged)

  # Whether or not /kyc rejected it, the decisive property is that
  # rent_motorcycle is STILL denied — the forged attributes were never granted.
  rent = client.run(a, name: "rent_motorcycle", reservation_id:)

  kyc_blocked  = Kiosk::Redteam.blocked?(kyc_resp)
  rent_blocked = rent.status == 403 && rent.body.is_a?(Hash) && rent.body["code"] == "kyc_required"

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

# ── skooti-local beat: the KYC gate cannot be walked around by verb ───────────
#
# MotorcycleForgedKyc above proves the attestation cannot be FORGED. This beat
# proves the gate cannot simply be BYPASSED — by calling the other verb.
#
# skooti has two rental verbs on one reservations table: start_rental (the
# licence-free electric scooter, no KYC by design — K-442) and rent_motorcycle
# (the combustion motorcycle, gated on age_over_18 AND licence_a). Nothing on
# the wire stops an assistant from reserving the MOTORCYCLE and then activating
# it with the SCOOTER verb, and until K-687 nothing in start_rental stopped it
# either: it selected `code` from the vehicle row and never looked at
# `needs_licence`, so reserve(MC-001) → pay → start_rental returned a signed
# Ed25519 unlock token for the KYC-gated motorcycle to an agent that had never
# attested anything. Every KYC driver called start_rental with SK-001 only, so
# no gate saw it.
#
# The agent here submits NO attestation at all — that is the point. It reserves
# and PAYS for MC-001 so nothing but the vehicle-kind check can be what blocks,
# then calls start_rental. A rental_token in the answer is a BREACH: it opens a
# real motorcycle to an unlicensed rider.
#
# CONTROL, in the same beat: the identical sequence on the licence-free SK-001
# must still return a token. Without it this beat would pass just as happily if
# start_rental were broken outright, or if pay/reserve had silently failed —
# "blocked" would prove nothing about the gate.
motorcycle_via_start_rental = lambda do
  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)
  a = client.register!(name: "redteam-mc-verbswap", pow_difficulty: 20)

  # Reserve + pay for a vehicle, and return its reservation_id.
  reserve_and_pay = lambda do |code|
    rsv = client.run(a, name: "reserve", scooter_code: code)
    raise "redteam(skooti): reserve #{code} failed (#{rsv.status})" unless rsv.status == 200
    reservation_id = rsv.body["reservation_id"]
    price_min      = rsv.body["price_per_min_cents"].to_i

    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    total     = price_min.positive? ? price_min : 100
    intent = { id: intent_id, user_id: a.user_id, agent_id: a.agent_id, iss: ISSUER,
               scope: "mobility", cap_amount_cents: total + 100, currency: "eur",
               exp: now + 600, iat: now }
    cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: a.user_id,
             agent_id: a.agent_id, iss: ISSUER,
             line_items: [{ sku: code, qty: 1, price_cents: total, reservation_id: }],
             total_amount_cents: total, currency: "eur", exp: now + 600, iat: now }
    pay_resp = client.pay(a, intent:, cart:)
    raise "redteam(skooti): pay #{code} failed (#{pay_resp.status})" unless pay_resp.status == 200

    reservation_id
  end

  fleet = client.query(a, name: "scooters_available")
  rows  = Array(fleet.body)
  raise "redteam(skooti): MC-001 not in fleet (verb-swap beat)" unless rows.any? { |r| r["code"] == "MC-001" }

  # THE ATTACK — motorcycle reservation, scooter verb, no attestation anywhere.
  mc_resv = reserve_and_pay.call("MC-001")
  attack  = client.run(a, name: "start_rental", reservation_id: mc_resv)
  token   = attack.body.is_a?(Hash) ? attack.body["rental_token"] : nil
  err     = attack.body.is_a?(Hash) ? attack.body["code"] : nil
  # The generic Kiosk::Redteam.blocked? is not the right judge here (the
  # MalformedUuidArg reasoning): it would call a 500 or an incidental "no
  # settlement" 403 a block. The refusal has to be TYPED — one of the wire
  # vocabulary's client-error codes, never a 5xx — and it has to be THIS gate,
  # which is what naming the other verb proves.
  # The whole problem document is the refusal now — `detail` and `hint` are its
  # top-level members, so there is no nested `error` object to serialize.
  refusal_text  = JSON.generate(attack.body)
  typed_refusal = [400, 403].include?(attack.status) &&
                  %w[bad_request forbidden kyc_required].include?(err)
  names_verb    = refusal_text.include?("rent_motorcycle")

  # THE CONTROL — same agent, same sequence, licence-free vehicle.
  sc_resv    = reserve_and_pay.call("SK-001")
  control    = client.run(a, name: "start_rental", reservation_id: sc_resv)
  sc_token   = control.body.is_a?(Hash) ? control.body["rental_token"] : nil
  control_ok = control.status == 200 && !sc_token.to_s.empty?

  if token && !token.to_s.empty?
    { blocked: false,
      detail:  "start_rental issued an unlock token for the KYC-GATED MC-001 to an agent with no attestation " \
               "(HTTP #{attack.status}, token #{token.to_s[0, 32]}…) — the licence gate was walked around by verb" }
  elsif !typed_refusal
    { blocked: false,
      detail:  "start_rental on MC-001 answered HTTP #{attack.status} code=#{err.inspect} — no token, but not a typed client-error refusal either" }
  elsif !names_verb
    { blocked: false,
      detail:  "start_rental on MC-001 refused (HTTP #{attack.status} #{err.inspect}) but never names rent_motorcycle — " \
               "an assistant is left with no completable path, and this may not even be the licence gate: #{refusal_text}" }
  elsif !control_ok
    { blocked: false,
      detail:  "CONTROL FAILED: start_rental on the licence-free SK-001 returned HTTP #{control.status} with no token — " \
               "the MC-001 refusal proves nothing (the verb, the payment or the harness is broken)" }
  else
    { blocked: true,
      detail:  "start_rental refuses the KYC-gated MC-001 (HTTP #{attack.status} #{err.inspect}), no rental_token; " \
               "control: the licence-free SK-001 still unlocks (HTTP #{control.status})" }
  end
end

mc_verbswap_beat = motorcycle_via_start_rental.call

# ── skooti-local beat: issued-jws cannot be stolen across agents ──────
#
# The broker (design §4.5) signs a claim for the request's OWN subject. This beat
# proves an ISSUED, VALID broker jws cannot be lifted onto a DIFFERENT agent:
# victim B opens request_kyc (skooti calls the broker), the human approves B's
# request on the BROKER page, the broker POSTs the signed claim to skooti's
# callback, and B receives via kyc_status a real broker-signed jws bound to B's
# user_id. Attacker A — which has reserved + paid for its OWN motorcycle so ONLY
# the KYC-attribute gate can block — submits B's jws to /agents/kyc. The
# KycVerifier binds `sub` to the authenticated identity, so it rejects (subject
# mismatch) → A's attributes are never granted → A's rent_motorcycle stays 403
# kyc_required. A bug that dropped the sub check would let any agent replay
# someone else's licence — a real BREACH. (Broker-minted now; the sub-binding
# defense is identical — design §5.5.)
kyc_jws_theft = lambda do
  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)

  # Victim B obtains a REAL broker-signed attestation: request_kyc → approve on
  # the broker → broker callback parks the jws → kyc_status returns it.
  b = client.register!(name: "redteam-kyc-victim-b", pow_difficulty: 20)
  req_b = client.run(b, name: "request_kyc")
  raise "redteam(skooti): request_kyc(B) failed (#{req_b.status})" unless req_b.status == 200
  token_b = req_b.body["request_id"]
  approve_rc = broker_approve(token_b)
  raise "redteam(skooti): approve(B) on broker failed (#{approve_rc})" unless approve_rc == 200

  # Poll kyc_status until the broker's async callback lands the jws.
  victim_jws = nil
  20.times do
    status_b = client.query(b, name: "kyc_status", request_id: token_b)
    victim_jws = Array(status_b.body).first&.dig("kyc_jws")
    break if victim_jws && !victim_jws.empty?
    sleep 0.2
  end
  raise "redteam(skooti): kyc_status(B) returned no jws" if victim_jws.nil? || victim_jws.empty?

  # Attacker A reserves + pays its OWN motorcycle so ONLY the KYC gate can block.
  a = client.register!(name: "redteam-kyc-attacker-a", pow_difficulty: 20)
  fleet = client.query(a, name: "scooters_available")
  mc    = Array(fleet.body).find { |r| r["code"] == "MC-001" }
  raise "redteam(skooti): MC-001 not in fleet (theft beat)" unless mc

  rsv = client.run(a, name: "reserve", scooter_code: "MC-001")
  raise "redteam(skooti): reserve MC-001(A) failed (#{rsv.status})" unless rsv.status == 200
  reservation_id = rsv.body["reservation_id"]
  price_min      = rsv.body["price_per_min_cents"].to_i

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
  rent_blocked = rent.status == 403 && rent.body.is_a?(Hash) && rent.body["code"] == "kyc_required"

  if kyc_blocked && rent_blocked
    { blocked: true, detail: "B's issued jws rejected for A at /kyc (#{kyc_resp.status}); A's rent_motorcycle stays 403 kyc_required" }
  elsif rent_blocked
    { blocked: true, detail: "B's issued jws not granted to A; rent_motorcycle stays 403 kyc_required" }
  else
    { blocked: false, detail: "stolen jws unlocked A's motorcycle: /kyc=#{kyc_resp.status}, rent_motorcycle=#{rent.status}" }
  end
end

theft_beat = kyc_jws_theft.call

# ── broker beat: a claim minted for a DIFFERENT operator is rejected ──────────
#
# Cross-operator replay defense (design §4.4 / §5.5), enforced at the DEMO LAYER
# in skooti's callback (the engine attestation/wire is unchanged). A claim the
# broker minted addressed to operator "other-operator" (aud/operator) must be
# rejected when POSTed to skooti's /kyc/callback — skooti only accepts claims
# addressed to ITSELF. We open a real skooti request (so the request_id/nonce are
# valid and pending) but mint the claim for a DIFFERENT operator with the broker
# ProveKey, then deliver it to skooti's callback. skooti must reject (operator
# mismatch) → kyc_status stays pending → the agent stays 403 kyc_required. A bug
# that dropped the operator check would let a claim solicited by/for another
# operator unlock skooti — a real BREACH.
cross_operator_replay = lambda do
  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)
  a = client.register!(name: "redteam-xop", pow_difficulty: 20)

  # Open a real skooti request so the callback correlates to a pending row.
  req = client.run(a, name: "request_kyc")
  raise "redteam(skooti): request_kyc(xop) failed (#{req.status})" unless req.status == 200
  request_id = req.body["request_id"]

  # Read the nonce skooti stored (the broker returned it to skooti at intake and
  # echoes it in a real callback). We fetch it from the broker's intake response
  # by starting an equivalent request — but simplest is to mint a claim carrying
  # the SAME nonce the broker holds for this request_id. The broker won't hand us
  # its stored nonce, so we forge a claim for a DIFFERENT operator and let the
  # callback's OPERATOR check fire regardless of nonce. To isolate the operator
  # check we pass the correct nonce shape but a wrong operator; even if the nonce
  # differed the callback would still reject, so this test is conservative.
  #
  # Mint a broker-signed claim for a DIFFERENT operator, bound to A's subject.
  forged_operator_jws = ProveTestIssuer.keypair && begin
    now = Time.now.to_i
    JWT.encode(
      { sub: a.user_id, level: "verified", iss: ProveTestIssuer.issuer,
        operator: "other-operator", aud: "other-operator",
        request_id:, nonce: "any", iat: now, exp: now + 3600,
        attributes: { age_over_18: true, licence_a: true } },
      ProveTestIssuer.keypair, "RS256",
    )
  end

  cb_rc = post_kyc_callback(request_id:, kyc_jws: forged_operator_jws, nonce: "any")

  # The callback must reject (403/404). The agent's rent stays blocked because
  # kyc_status never reaches approved.
  st = client.query(a, name: "kyc_status", request_id:)
  status = Array(st.body).first&.dig("status")
  callback_rejected = cb_rc != 200
  still_pending     = status != "approved"

  # ENGINE-LEVEL block (the aud operator-binding): submit the wrong-aud claim
  # DIRECTLY to the wire endpoint POST /kiosk/agents/kyc, bypassing skooti's
  # callback entirely. The claim's sub IS A (so sub-binding passes) — only its
  # aud is wrong. The engine KycVerifier MUST reject it (aud != skooti's
  # kyc_audience), so a cross-operator claim cannot be stamped even if the
  # demo's callback check were skipped. This is the wire-level guarantee.
  wire_resp    = client.kyc(a, attestation_jws: forged_operator_jws)
  wire_blocked = Kiosk::Redteam.blocked?(wire_resp)

  if callback_rejected && still_pending && wire_blocked
    { blocked: true, detail: "cross-operator claim rejected at BOTH the engine wire (POST /kiosk/agents/kyc → #{wire_resp.status}, aud mismatch) and /kyc/callback (#{cb_rc}); kyc_status stays #{status.inspect}" }
  elsif !wire_blocked
    { blocked: false, detail: "ENGINE BREACH: wrong-aud claim accepted at the wire (POST /kiosk/agents/kyc=#{wire_resp.status})" }
  else
    { blocked: false, detail: "cross-operator claim accepted at the callback: callback=#{cb_rc}, kyc_status=#{status.inspect}" }
  end
end

xop_beat = cross_operator_replay.call

# ── broker beat: an unsigned / wrong-key callback is rejected ─────────────────
#
# Callback authenticity (design §4.8 / §5.5): skooti's /kyc/callback verifies the
# jws against the trusted ProveKey. A callback whose jws is signed by the WRONG
# key (trusted issuer, bad signature) — or is missing entirely — must be
# rejected, so a forged callback cannot stamp a claim. We open a real skooti
# request, then POST a callback carrying a wrong-key jws for A's subject. skooti
# must reject → kyc_status stays pending → agent stays 403. A weakened signature
# check would let anyone forge a callback and unlock — a real BREACH.
forged_callback_no_sig = lambda do
  client = Kiosk::Redteam::Client.new(base_url: BASE_URL)
  a = client.register!(name: "redteam-fcb", pow_difficulty: 20)

  req = client.run(a, name: "request_kyc")
  raise "redteam(skooti): request_kyc(fcb) failed (#{req.status})" unless req.status == 200
  request_id = req.body["request_id"]

  now = Time.now.to_i
  # Wrong key, trusted issuer, addressed to skooti — ONLY the signature is bad.
  wrong_key_jws = JWT.encode(
    { sub: a.user_id, level: "verified", iss: ProveTestIssuer.issuer,
      operator: ProveTrust.operator_id, aud: ProveTrust.operator_id,
      request_id:, nonce: "any", iat: now, exp: now + 3600,
      attributes: { age_over_18: true, licence_a: true } },
    FORGED_KYC_KEY, "RS256",
  )

  cb_wrong = post_kyc_callback(request_id:, kyc_jws: wrong_key_jws, nonce: "any")
  # Also a callback with NO jws at all.
  cb_missing = post_kyc_callback(request_id:, nonce: "any")

  st = client.query(a, name: "kyc_status", request_id:)
  status = Array(st.body).first&.dig("status")

  wrong_rejected   = cb_wrong != 200
  missing_rejected = cb_missing != 200
  still_pending    = status != "approved"

  if wrong_rejected && missing_rejected && still_pending
    { blocked: true, detail: "wrong-key callback (#{cb_wrong}) and no-jws callback (#{cb_missing}) both rejected; kyc_status stays #{status.inspect}" }
  else
    { blocked: false, detail: "forged callback accepted: wrong=#{cb_wrong}, missing=#{cb_missing}, kyc_status=#{status.inspect}" }
  end
end

fcb_beat = forged_callback_no_sig.call

# ── 0.4-cutover beats: the shape of the wire itself ──────────────────────────
#
# Two beats that could not be written before the cutover (T-074 = A), because
# before it both answers were something else. They share one principal: neither
# touches the fleet or the reservations table, so nothing is staged and there is
# nothing for a second identity to isolate.
wire_probe = Kiosk::Redteam::Client.new(base_url: BASE_URL)
                                   .register!(name: "redteam-wire-shape", pow_difficulty: 20)

# One raw request, bypassing the redteam Client — the whole point is to dial
# paths and methods the Client will not construct.
raw_wire = lambda do |method, path, body = nil|
  uri = URI("#{BASE_URL}#{path}")
  req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post)
          .new(uri, { "Content-Type" => "application/json",
                      "Authorization" => "Bearer #{wire_probe.token}" })
  req.body = JSON.generate(body) if body
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res, (JSON.parse(res.body) rescue {})]
end

# RetiredWire — `POST /kiosk/query` and `POST /kiosk/run` are DELETED, not
# tombstoned. They now reach the per-verb controller as verbs literally named
# "query" and "run", which nobody registered, so they answer the ordinary 404:
# no privileged endpoint left, no compatibility payload that would keep the 0.3
# argument channel alive, and no second conformance surface to attack. A
# deprecation shim here would be exactly that second surface — and it is the one
# an attacker would reach for, because it took the verb name from the BODY.
retired_wire = lambda do
  probes = %w[query run].map do |name|
    res, body = raw_wire.call(:post, "/kiosk/#{name}", { name: "scooters_available" })
    [res.code.to_i == 404 && body["code"] == "not_found",
     "POST /kiosk/#{name} → #{res.code}/#{body["code"].inspect}"]
  end

  if probes.all? { |ok, _| ok }
    { blocked: true,
      detail:  "the 0.3 multiplexed pair is gone: #{probes.map(&:last).join(", ")} " \
               "(an ordinary not_found, with no compatibility payload)" }
  else
    { blocked: false,
      detail:  "a retired 0.3 endpoint still answers: #{probes.map(&:last).join(", ")} " \
               "(want 404/\"not_found\" for both)" }
  end
end

retired_wire_beat = retired_wire.call

# MethodMismatch — a GET at an action's path is 405 with `Allow: POST`, never a
# silent 404. The resource EXISTS; answering 404 would be a lie about it, and an
# assistant that read the 404 as "this operator cannot do that" would abandon a
# verb it could have called correctly. Probed in BOTH directions, because the
# fork is symmetric and only one half is interesting to get right by accident:
# a GET at the action `reserve`, and a POST at the query `my_reservations`.
method_mismatch = lambda do
  probes = [
    [:get,  "/kiosk/reserve",         "POST", nil],
    [:post, "/kiosk/my_reservations", "GET",  {}],
  ].map do |method, path, wanted, body|
    res, doc = raw_wire.call(method, path, body)
    ok = res.code.to_i == 405 && doc["code"] == "method_not_allowed" &&
         res["allow"].to_s.upcase.include?(wanted)
    [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc["code"].inspect} " \
         "Allow=#{res["allow"].inspect} (want 405/method_not_allowed/#{wanted})"]
  end

  if probes.all? { |ok, _| ok }
    { blocked: true,
      detail:  "the wrong method on a real verb is a 405 that names the right one: " \
               "#{probes.map(&:last).join("; ")}" }
  else
    { blocked: false,
      detail:  "a method mismatch is not answered 405/method_not_allowed with Allow: " \
               "#{probes.map(&:last).join("; ")}" }
  end
end

method_mismatch_beat = method_mismatch.call

# ── SelfAssertedTokenForgery (K-539, restated by T-104) — OVER THE LIVE WIRE ──
# THE BEAT OUTLIVED ITS TARGET, WHICH IS WHY IT IS STILL HERE. It used to be an
# IN-PROCESS proof about a door that was only shut in production: skooti shipped
# a hand-copied composite agent-IdP whose cleartext fallback parsed
# `agent:u-…:a-…:r-…` into an identity at whatever role the string named, and it
# was INTENTIONALLY live wherever `Rails.env.local?` — which is exactly the
# environment demo:redteam boots. So the dev wire could not demonstrate the
# block, and this beat had to stub `Rails.env` to "production", assert NO
# identity there, and then assert that development still ACCEPTED the forgery,
# because every driver depended on it doing so.
#
# T-104 deleted the parser instead of gating it. Agent auth is the engine's own
# kiosk-pop verifier now — it has no cleartext branch to fall back to in any
# environment — and no driver wants one, because they all earn a real token
# through the shipped ceremony. So the beat becomes what it should always have
# been, exactly as its human sibling below did at T-066: an over-the-wire probe
# in the SAME environment the drivers run in, with no `Rails.env` anywhere in
# it and no environment condition in the verdict. A self-asserted bearer
# resolves to NO identity, unconditionally.
#
# The first probe is the STRONGEST form of the attack rather than the easiest:
# it names a real account and a real agent — `wire_probe`'s, minted by the
# shipped registration a few lines above — and escalates the role to `owner`,
# so nothing in the string is invented except the claim that it is a
# credential. The second is the wholly-made-up one the old beat used. The
# positive control is the same verb over the same wire with `wire_probe`'s REAL
# token, so a 401 above is the forgery being refused rather than the surface
# being down.
#
# Unit proof of the same property, from the other side:
# kiosk-test-support spec/demo_agent_idp_is_real_spec.rb.
self_asserted_token_forgery = lambda do
  probe = lambda do |token|
    uri = URI("#{BASE_URL}/kiosk/my_reservations")
    req = Net::HTTP::Get.new(uri, { "Authorization" => "Bearer #{token}" })
    Net::HTTP.new(uri.host, uri.port).request(req).code.to_i
  end

  forgeries = [
    ["real account + real agent, role escalated to owner",
     "agent:u-#{wire_probe.user_id}:a-#{wire_probe.agent_id}:r-owner"],
    ["wholly invented ids",
     "agent:u-#{SecureRandom.uuid}:a-#{SecureRandom.uuid}:r-owner"],
  ].map do |label, token|
    code = probe.call(token)
    [code == 401, "#{label} → #{code}"]
  end

  control_res, = raw_wire.call(:get, "/kiosk/my_reservations")
  control_ok   = control_res.code.to_i == 200

  if forgeries.all? { |ok, _| ok } && control_ok
    { blocked: true,
      detail: "self-asserted `agent:u-…:r-owner` bearer resolves to NO identity — " \
              "#{forgeries.map(&:last).join("; ")} — in the SAME (development) env the " \
              "drivers run in, with no environment condition in the assertion; the real " \
              "registered token answers the same verb #{control_res.code}, so the refusal " \
              "is not vacuous" }
  elsif !control_ok
    { blocked: false,
      detail: "unexpected: the REAL registered token was refused too " \
              "(HTTP #{control_res.code}) — the 401s above prove nothing" }
  else
    { blocked: false,
      detail: "K-539 REGRESSION: a self-asserted bearer was accepted over the wire — " \
              "#{forgeries.map(&:last).join("; ")} (want 401 for each)" }
  end
rescue StandardError => e
  { blocked: false, detail: "beat error: #{e.class}: #{e.message}" }
end

self_asserted_beat = self_asserted_token_forgery.call

# ── SelfAssertedUserBearerForgery (K-555 / T-066) — OVER THE LIVE WIRE ────────
# The HUMAN sibling of the K-539 agent-stub forgery, and it changed shape when
# the stub it used to attack was deleted.
#
# Until T-066 skooti shipped a StubUserIdp that parsed an UNSIGNED, self-asserted
# `user:u-<uuid>` bearer into a HUMAN identity, live in development so the
# binding ceremonies could be walked without a real login. The block could only
# be shown IN-PROCESS, against a stubbed production Rails.env, because the dev
# wire this suite drives was supposed to accept the forgery.
#
# skooti now authenticates humans with real Devise in EVERY environment, so the
# forgery has no arm to land on and the beat can be what it always should have
# been: an over-the-wire probe in the SAME environment the drivers run in. A
# forged `user:u-<uuid>` bearer at the account-binding surface must resolve to
# no human at all — POST /kiosk/auth/link answers 401 — and the positive control
# is the real thing: the seeded rider signs in at /users/sign_in and the SAME
# endpoint answers her.
require_relative "devise_session"

self_asserted_user_bearer_forgery = lambda do
  anon = DeviseSession.new(BASE_URL)
  rc_forged, = anon.post_json(
    "/kiosk/auth/link", {}, { "Authorization" => "user:u-#{SecureRandom.uuid}" }
  )

  # Positive control: the honest channel still works, so a 401 above is the
  # forgery being refused rather than the surface being broken.
  rider = DeviseSession.new(BASE_URL)
                       .sign_in!(email: "ada@example.com", password: "skooti-demo-password")
  rc_real, = rider.post_json("/kiosk/auth/link", {}, { session: true })

  if rc_forged == 401 && [200, 201].include?(rc_real)
    { blocked: true,
      detail: "forged self-asserted `user:u-…` human bearer → 401 at /kiosk/auth/link in the " \
              "SAME env the drivers run in (no stub arm left); the real Devise session mints " \
              "a link code (#{rc_real}), so the refusal is not vacuous" }
  elsif rc_forged != 401
    { blocked: false,
      detail: "K-555 REGRESSION: forged self-asserted human bearer was accepted at " \
              "/kiosk/auth/link (HTTP #{rc_forged})" }
  else
    { blocked: false,
      detail: "unexpected: the REAL Devise session was refused too (HTTP #{rc_real}) — the " \
              "401 above proves nothing" }
  end
rescue StandardError => e
  { blocked: false, detail: "beat error: #{e.class}: #{e.message}" }
end

self_asserted_user_beat = self_asserted_user_bearer_forgery.call

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
if mc_verbswap_beat[:blocked]
  puts "  BLOCKED  ✓ MotorcycleViaStartRental — #{mc_verbswap_beat[:detail]}"
else
  puts "  BREACH   ✗ MotorcycleViaStartRental — #{mc_verbswap_beat[:detail]}"
end
if theft_beat[:blocked]
  puts "  BLOCKED  ✓ IssuedKycJwsTheft — #{theft_beat[:detail]}"
else
  puts "  BREACH   ✗ IssuedKycJwsTheft — #{theft_beat[:detail]}"
end
if xop_beat[:blocked]
  puts "  BLOCKED  ✓ CrossOperatorClaimReplay — #{xop_beat[:detail]}"
else
  puts "  BREACH   ✗ CrossOperatorClaimReplay — #{xop_beat[:detail]}"
end
if fcb_beat[:blocked]
  puts "  BLOCKED  ✓ ForgedCallbackNoSig — #{fcb_beat[:detail]}"
else
  puts "  BREACH   ✗ ForgedCallbackNoSig — #{fcb_beat[:detail]}"
end
if retired_wire_beat[:blocked]
  puts "  BLOCKED  ✓ RetiredWire — #{retired_wire_beat[:detail]}"
else
  puts "  BREACH   ✗ RetiredWire — #{retired_wire_beat[:detail]}"
end
if method_mismatch_beat[:blocked]
  puts "  BLOCKED  ✓ MethodMismatch — #{method_mismatch_beat[:detail]}"
else
  puts "  BREACH   ✗ MethodMismatch — #{method_mismatch_beat[:detail]}"
end
if self_asserted_beat[:blocked]
  puts "  BLOCKED  ✓ SelfAssertedTokenForgery — #{self_asserted_beat[:detail]}"
else
  puts "  BREACH   ✗ SelfAssertedTokenForgery — #{self_asserted_beat[:detail]}"
end
if self_asserted_user_beat[:blocked]
  puts "  BLOCKED  ✓ SelfAssertedUserBearerForgery — #{self_asserted_user_beat[:detail]}"
else
  puts "  BREACH   ✗ SelfAssertedUserBearerForgery — #{self_asserted_user_beat[:detail]}"
end

all_beats = [mc_beat, mc_verbswap_beat, theft_beat, xop_beat, fcb_beat,
             retired_wire_beat, method_mismatch_beat,
             self_asserted_beat, self_asserted_user_beat]
local_beats_blocked = all_beats.count { |b| b[:blocked] }
blocked_count = blocked_results.size + local_beats_blocked
beat_breach   = all_beats.count { |b| !b[:blocked] }

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
