# frozen_string_literal: true

# Red-team battery for skooti: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3004 bundle exec ruby script/redteam_suite.rb

require "kiosk/redteam"
require "jwt"
require "openssl"
require "securerandom"
require "net/http"
require "uri"
require "json"

# KYC attestations: valid/expired signed with the broker's key, forged with a wrong key under the trusted issuer.
require_relative "prove_test_issuer"

BASE_URL = ENV.fetch("SERVER_URL")
ISSUER   = BASE_URL
# The KYC broker as config/environments/development.rb points this origin at it.
BROKER_URL     = "http://127.0.0.1:3020"
TRUSTED_ISSUER = ProveTestIssuer.issuer
# The seeded rider (db/seeds.rb).
RIDER_EMAIL   = "ada@example.com"
DEMO_PASSWORD = "skooti-demo-password"

# Wrong key, trusted issuer: only the signature is bad.
FORGED_KYC_KEY = OpenSSL::PKey::RSA.generate(2048)

def attest_forged(user_id)
  now = Time.now.to_i
  JWT.encode(
    {
      sub:   user_id,
      level: "verified",
      iss:   TRUSTED_ISSUER,  # trusted issuer; ONLY the signature is wrong
      aud:   ProveTestIssuer.audience,  # correct audience — isolates the signature defect
      iat:   now,
      exp:   now + 3600,
    },
    FORGED_KYC_KEY,
    "RS256",
  )
end

# The broker's approval as the human gives it, and skooti's KYC callback reached directly.

def broker_approve(request_id)
  uri = URI("#{BROKER_URL}/verify")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
  req.body = URI.encode_www_form(request: request_id, decision: "approve")
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  res.code.to_i
end

def post_kyc_callback(body)
  uri = URI("#{BASE_URL}/kiosk/kyc/callback")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  res.code.to_i
end

# The kyc_verification events this principal's stream replays from the start.
def kyc_events_for(principal)
  stream = Kiosk::TestHelpers::Assistant::Events.new(base_url: BASE_URL, token: principal.token)
  stream.subscribe("kyc_verification", since: 0)
  stream.listen(2)
ensure
  stream&.close
end

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 20,     # >0 turns the Equihash /register gate on; not an Equihash parameter
  requires_kyc:   true,   # rent_motorcycle is attribute-gated; start_rental refuses licence vehicles
  currency:       "eur",
  declared_roles: %w[customer],

  per_user_query: "my_reservations",

  row_id_key:    "reservation_id",
  result_id_key: "reservation_id",

  # Reserves the first available scooter; reserve needs no KYC.
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

  # reserve declares only scooter_code, so an injected user_id is a typed 400.
  forge_action: "reserve",
  forge_args:   lambda { |client, principal_a, _principal_b|
    fleet_resp = client.query(principal_a, name: "scooters_available")
    rows       = fleet_resp.body.is_a?(Array) ? fleet_resp.body : []
    scooter    = rows.first
    raise "redteam(skooti): no scooters for forge_args" unless scooter

    { scooter_code: scooter["code"] }
  },

  gated_action: "start_rental",
  gated_args:   ->(ref) { { reservation_id: ref[:id] } },

  # The mandate shapes script/rental_flow.rb builds.
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
      line_items:         [{ qty: 1, price_cents: total_cents, reservation_id: owned_ref[:id] }],
      total_amount_cents: total_cents,
      currency:           "eur",
      exp:                now + 600,
      iat:                now,
    }

    { intent: intent, cart: cart }
  },

  kyc_valid:   ->(user_id) { ProveTestIssuer.attest(user_id: user_id) },
  kyc_expired: ->(user_id) { ProveTestIssuer.attest_expired(user_id: user_id) },
  kyc_forged:  method(:attest_forged),
)

# Cashier checks on the agent's own reservation: the operator prices what lands on the counter.

class TamperedPriceCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "TamperedPriceCart",
      category:    "payment",
      description: "A cart whose total is below the operator's quoted rental price must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)

    # The line matches the lowered total, so only the quote check can refuse it.
    quoted        = owned[:price_per_min_cents].to_i
    quoted        = 100 if quoted <= 0
    lowered_total = quoted - 50
    m[:cart] = m[:cart].merge(
      line_items:         [{ qty: 1, price_cents: lowered_total, reservation_id: owned[:id] }],
      total_amount_cents: lowered_total,
    )
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 by name: a 401 would mean the cashier never priced the cart.
    verdict_from(resp, expect: 403, detail: "below-quote total settled (HTTP #{resp.status})")
  end
end

class InflatedTotalCart < Kiosk::Redteam::Scenario
  def initialize
    super(
      name:        "InflatedTotalCart",
      category:    "payment",
      description: "A cart whose total exceeds the sum of its line items must be rejected at capture",
    )
  end

  def call(client, profile)
    a = client.register!
    owned = profile.create_owned.call(client, a)
    m = profile.pay_for.call(client, a, owned)
    # pay_for's single priced line sums to total_cents; inflate the total only.
    quoted = owned[:price_per_min_cents].to_i
    quoted = 100 if quoted <= 0
    m[:cart] = m[:cart].merge(total_amount_cents: quoted + 50)
    resp = client.pay(a, intent: m[:intent], cart: m[:cart])
    # 403 by name — see TamperedPriceCart above.
    verdict_from(resp, expect: 403, detail: "total above the line-item sum settled (HTTP #{resp.status})")
  end
end

# A junk reservation_id — on start_rental, rent_motorcycle and inside a signed cart — is a typed 400
# with no SQL internals; the cart probe reaches Kiosk::UuidCheck, which no input_schema covers.
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
    a = client.register!
    # rent_motorcycle's attribute gate runs first; clear it so the uuid check is reached.
    kyc = client.kyc(a, attestation_jws: ProveTestIssuer.attest(
      user_id: a.user_id, attributes: { age_over_18: true, licence_a: true },
    ))
    raise "redteam(skooti): MalformedUuidArg fixture broken — /kyc returned #{kyc.status}" unless kyc.status == 200

    failures = []
    statuses = []

    MALFORMED.each do |junk|
      check(failures, statuses, "start_rental(#{junk.inspect})",
            client.run(a, name: "start_rental", reservation_id: junk), supplied: junk)
      check(failures, statuses, "rent_motorcycle(#{junk.inspect})",
            client.run(a, name: "rent_motorcycle", reservation_id: junk), supplied: junk)
      check(failures, statuses, "pay cart reservation_id=#{junk.inspect}",
            pay_with_ref(client, a, junk), supplied: junk)
    end

    # Control: a well-formed unknown id must reach the cashier's 403, or the 400s above prove nothing.
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

  # supplied: the probe's own bytes, so an echoed value is not reported as a leak.
  def check(failures, statuses, label, resp, supplied: nil)
    statuses << resp.status
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, SQL_INTERNALS, supplied: supplied)
    code = resp.body.is_a?(Hash) ? resp.body["code"] : nil
    return if resp.status == 400 && code == "bad_request" && !scan.leak?

    failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}" \
                "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end

  # Reserves nothing: the shape check runs before the cashier, so the shared fleet is untouched.
  def pay_with_ref(client, principal, junk)
    now       = Time.now.to_i
    intent_id = SecureRandom.uuid
    intent = { id: intent_id, user_id: principal.user_id, agent_id: principal.agent_id,
               iss: ISSUER, scope: "mobility", cap_amount_cents: 200, currency: "eur",
               exp: now + 600, iat: now }
    cart = { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: principal.user_id,
             agent_id: principal.agent_id, iss: ISSUER,
             line_items: [{ qty: 1, price_cents: 100, reservation_id: junk }],
             total_amount_cents: 100, currency: "eur", exp: now + 600, iat: now }
    client.pay(principal, intent:, cart:)
  end
end

# Non-string JSON shapes on every skooti argument are a typed 400; an unknown scooter_code reaches ReserveOperation.
class HostileArgShapes < Kiosk::Redteam::Scenario
  LEAKS = ["::uuid", "PG::", "22P02", "invalid input syntax", "NoMethodError",
           "TypeError", "undefined method", "ActiveRecord::"].freeze

  # The five families of hostile shape, as a string argument can carry them.
  SHAPES = [true, false, [], {}, ["SK-001"], { "code" => "SK-001" }, 1, 1.5].freeze

  def initialize
    super(
      name:        "HostileArgShapes",
      category:    "input",
      description: "Boolean/array/object/number arguments on scooter_code and reservation_id are a typed 400 — never a 500",
    )
  end

  def call(client, profile)
    a         = client.register!
    @failures = []

    SHAPES.each do |v|
      refused "reserve scooter_code=#{v.inspect}",
              client.run(a, name: "reserve", scooter_code: v), supplied: v
      refused "start_rental reservation_id=#{v.inspect}",
              client.run(a, name: "start_rental", reservation_id: v), supplied: v
      refused "rent_motorcycle reservation_id=#{v.inspect}",
              client.run(a, name: "rent_motorcycle", reservation_id: v), supplied: v
    end

    # The one that reaches ReserveOperation: a well-typed but unknown handle.
    refused "reserve scooter_code=\"NO-SUCH-VEHICLE\"",
            client.run(a, name: "reserve", scooter_code: "NO-SUCH-VEHICLE"),
            supplied: "NO-SUCH-VEHICLE"

    # Control for the leak scan: a needle ReserveOperation echoes back from the probe is not a leak.
    echo_control = "PG:: 22P02 invalid input syntax"
    echo_resp    = client.run(a, name: "reserve", scooter_code: echo_control)
    refused "reserve scooter_code=<a value spelling three LEAKS> (oracle control)",
            echo_resp, supplied: echo_control
    # Vacuous unless the refusal really echoed the value.
    unless JSON.generate(echo_resp.body).include?(echo_control)
      @failures << "CONTROL VACUOUS: reserve did not echo the scooter_code it refused, so the " \
                   "oracle was never asked to tell an echo from a leak"
    end

    # Control: a real vehicle code still reserves.
    fleet = client.query(a, name: "scooters_available").body
    raise "redteam(skooti): empty fleet" unless fleet.is_a?(Array) && fleet.any?

    control = client.run(a, name: "reserve", scooter_code: fleet.first["code"])
    unless control.status == 200
      @failures << "CONTROL well-formed reserve → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 90]} (want 200; the probes above prove nothing " \
                   "on an origin that refuses everything)"
    end

    Kiosk::Redteam::Verdict.new(
      blocked: @failures.empty?, skipped: false, status: 400,
      detail:  @failures.join(" | "),
    )
  end

  private

  # supplied: the probe's own bytes, so an echoed value is not reported as a leak.
  def refused(label, resp, supplied: nil)
    doc  = resp.body.is_a?(Hash) ? resp.body : {}
    scan = Kiosk::Redteam::LeakScan.scan(resp.body, LEAKS, supplied: supplied)
    return if resp.status == 400 && doc["code"] == "bad_request" && !scan.leak?

    @failures << "#{label} → HTTP #{resp.status} code=#{doc["code"].inspect}" \
                 "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}"
  end
end

scenarios = [
  Kiosk::Redteam::Scenarios::PayForOtherUseSelf.new,     # C2 — headline
  Kiosk::Redteam::Scenarios::SpentResourceReuse.new,     # C3
  # No MissingKyc: start_rental only activates licence-free vehicles (MotorcycleViaStartRental).
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
  # Role self-selection at the unauthenticated device_authorization request.
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  Kiosk::Redteam::Scenarios::WrongCurrencyCart.new,                                 # cashier check — currency
  TamperedPriceCart.new,                                 # cashier check — below quote
  InflatedTotalCart.new,                                 # cashier check — total ≠ line sum
  MalformedUuidArg.new,                                  # junk uuid → typed 400, no 500
  HostileArgShapes.new,                                  # boolean/array/object/number shapes → typed 400
]

# skooti exposes the full surface: no library scenario may skip.
EXPECTED_SKIP_NAMES = [].freeze

puts "\n── skooti redteam battery ──"
puts "  base_url:              #{BASE_URL}"
puts "  register gate:         Equihash n=96 k=5 " \
     "(profile pow_difficulty: #{profile.pow_difficulty} → RegistrationWithoutPow " \
     "#{profile.pow_difficulty > 0 ? %(applicable) : %(SKIPPED)})"
puts "  requires_kyc:          #{profile.requires_kyc}"
# The registry only; the local beats below are counted in the summary.
puts "  registered scenarios:  #{scenarios.size} (skooti-local beats run after them; the summary counts both)"
puts ""

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# MotorcycleForgedKyc: wrong-key licence attributes must not unlock rent_motorcycle.
motorcycle_forged_kyc = lambda do
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
  a = client.register!

  # Reserve and pay first, so only the KYC-attribute gate can block.
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
           iss: ISSUER, line_items: [{ qty: 1, reservation_id: }],
           total_amount_cents: total, currency: "eur", exp: now + 600, iat: now }
  pay_resp = client.pay(a, intent:, cart:)
  raise "redteam(skooti): pay MC-001 failed (#{pay_resp.status})" unless pay_resp.status == 200

  # Self-asserts both attributes, signed with the wrong key.
  forged = JWT.encode(
    { sub: a.user_id, level: "verified", iss: TRUSTED_ISSUER,
      aud: ProveTestIssuer.audience, iat: now, exp: now + 3600,
      attributes: { age_over_18: true, licence_a: true } },
    FORGED_KYC_KEY, "RS256",
  )
  kyc_resp = client.kyc(a, attestation_jws: forged)

  # Decisive: rent_motorcycle is still refused.
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

# MotorcycleViaStartRental: a paid MC-001 reservation cannot be activated with the scooter verb;
# the same sequence on SK-001 is the control.
motorcycle_via_start_rental = lambda do
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
  a = client.register!

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
             line_items: [{ qty: 1, price_cents: total, reservation_id: }],
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
  # A typed refusal naming rent_motorcycle, not any non-200.
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

# IssuedKycJwsTheft: B's broker-signed jws, submitted by A, must not unlock A's motorcycle.
kyc_jws_theft = lambda do
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)

  # Victim B gets a real broker-signed jws through request_kyc and the broker page.
  b = client.register!
  stream_b = Kiosk::TestHelpers::Assistant::Events.new(base_url: BASE_URL, token: b.token)
  stream_b.subscribe("kyc_verification")
  req_b = client.run(b, name: "request_kyc")
  raise "redteam(skooti): request_kyc(B) failed (#{req_b.status})" unless req_b.status == 200
  token_b = req_b.body["request_id"]
  approve_rc = broker_approve(token_b)
  raise "redteam(skooti): approve(B) on broker failed (#{approve_rc})" unless approve_rc == 200

  victim_jws = stream_b.await { |e| e.dig("data", "request_id") == token_b }.dig("data", "kyc_jws")
  stream_b.close
  raise "redteam(skooti): B's kyc_verification event carried no jws" if victim_jws.to_s.empty?

  # Attacker A reserves + pays its OWN motorcycle so ONLY the KYC gate can block.
  a = client.register!
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
           iss: ISSUER, line_items: [{ qty: 1, reservation_id: }],
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

# CrossOperatorClaimReplay: a claim addressed to another operator is refused at skooti's callback and at the engine wire.
cross_operator_replay = lambda do
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
  a = client.register!

  # Open a real skooti request so the callback correlates to a pending row.
  req = client.run(a, name: "request_kyc")
  raise "redteam(skooti): request_kyc(xop) failed (#{req.status})" unless req.status == 200
  request_id = req.body["request_id"]

  # Signed with the broker key but addressed to another operator; the nonce is not under test.
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

  # The callback must reject (403/404), so no attestation reaches the agent.
  callback_rejected = cb_rc != 200
  events            = kyc_events_for(a)
  still_pending     = events.empty?

  # The engine's aud check must refuse it alone, with the callback bypassed.
  wire_resp    = client.kyc(a, attestation_jws: forged_operator_jws)
  wire_blocked = Kiosk::Redteam.blocked?(wire_resp)

  if callback_rejected && still_pending && wire_blocked
    { blocked: true, detail: "cross-operator claim rejected at BOTH the engine wire (POST /kiosk/agents/kyc → #{wire_resp.status}, aud mismatch) and /kyc/callback (#{cb_rc}); no kyc_verification event sent" }
  elsif !wire_blocked
    { blocked: false, detail: "ENGINE BREACH: wrong-aud claim accepted at the wire (POST /kiosk/agents/kyc=#{wire_resp.status})" }
  else
    { blocked: false, detail: "cross-operator claim accepted at the callback: callback=#{cb_rc}, kyc_verification events=#{events.size}" }
  end
end

xop_beat = cross_operator_replay.call

# ForgedCallbackNoSig: a callback with a wrong-key jws, or none, is refused and emits no event.
forged_callback_no_sig = lambda do
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
  a = client.register!

  req = client.run(a, name: "request_kyc")
  raise "redteam(skooti): request_kyc(fcb) failed (#{req.status})" unless req.status == 200
  request_id = req.body["request_id"]

  now = Time.now.to_i
  # Wrong key, trusted issuer, addressed to skooti — ONLY the signature is bad.
  wrong_key_jws = JWT.encode(
    { sub: a.user_id, level: "verified", iss: ProveTestIssuer.issuer,
      operator: ProveTestIssuer.audience, aud: ProveTestIssuer.audience,
      request_id:, nonce: "any", iat: now, exp: now + 3600,
      attributes: { age_over_18: true, licence_a: true } },
    FORGED_KYC_KEY, "RS256",
  )

  cb_wrong = post_kyc_callback(request_id:, kyc_jws: wrong_key_jws, nonce: "any")
  # Also a callback with NO jws at all.
  cb_missing = post_kyc_callback(request_id:, nonce: "any")

  events = kyc_events_for(a)

  wrong_rejected   = cb_wrong != 200
  missing_rejected = cb_missing != 200
  still_pending    = events.empty?

  if wrong_rejected && missing_rejected && still_pending
    { blocked: true, detail: "wrong-key callback (#{cb_wrong}) and no-jws callback (#{cb_missing}) both rejected; no kyc_verification event sent" }
  else
    { blocked: false, detail: "forged callback accepted: wrong=#{cb_wrong}, missing=#{cb_missing}, kyc_verification events=#{events.size}" }
  end
end

fcb_beat = forged_callback_no_sig.call

# The wire-shape beats share one principal; neither touches the fleet.
wire_probe = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
                                   .register!

# A raw request the Client will not construct; bearer: false asks whether a credential changes the answer.
raw_wire = lambda do |method, path, body = nil, bearer: true|
  uri     = URI("#{BASE_URL}#{path}")
  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{wire_probe.token}" if bearer
  req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
  req.body = JSON.generate(body) if body
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res, (JSON.parse(res.body) rescue {})]
end

# POST /kiosk/query and /kiosk/run route nowhere: a plain 404, bearer or not, with no problem document.
unregistered_verb = lambda do
  probes = %w[query run].flat_map do |name|
    [[true, ""], [false, " (anon)"]].map do |bearer, tag|
      res, body = raw_wire.call(:post, "/kiosk/#{name}", { name: "scooters_available" },
                                bearer: bearer)
      [res.code.to_i == 404 && body["code"].nil?,
       "POST /kiosk/#{name}#{tag} → #{res.code}/#{body["code"].inspect} " \
       "(want 404 with no problem-document code)"]
    end
  end

  if probes.all? { |ok, _| ok }
    { blocked: true,
      detail:  "unregistered verb names #{probes.map(&:last).join(", ")} " \
               "(the ordinary 404 any undrawn path gets, bearer or not, " \
               "and no privileged surface either way)" }
  else
    { blocked: false,
      detail:  "an unregistered verb name answers the wrong thing: " \
               "#{probes.reject { |ok, _| ok }.map(&:last).join(", ")}" }
  end
end

unregistered_verb_beat = unregistered_verb.call

# MethodMismatch: the wrong method at a verb's path is a plain 404 with no Allow, both directions.
method_mismatch = lambda do
  probes = [
    [:get,  "/kiosk/reserve",         nil],
    [:post, "/kiosk/my_reservations", {}],
  ].map do |method, path, body|
    res, doc = raw_wire.call(method, path, body)
    ok = res.code.to_i == 404 && res["allow"].nil? && doc["code"].nil?
    [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc["code"].inspect} " \
         "Allow=#{res["allow"].inspect} (want a plain 404, no Allow, no code)"]
  end

  if probes.all? { |ok, _| ok }
    { blocked: true,
      detail:  "the wrong method on a real verb draws no route and never runs it: " \
               "#{probes.map(&:last).join("; ")}" }
  else
    { blocked: false,
      detail:  "a method mismatch is not answered as a plain 404: " \
               "#{probes.map(&:last).join("; ")}" }
  end
end

method_mismatch_beat = method_mismatch.call

# SelfAssertedTokenForgery: a self-asserted agent bearer, even naming a real account as owner,
# resolves to no identity; the real token is the control.
self_asserted_token_forgery = lambda do
  probe = lambda do |token|
    uri = URI("#{BASE_URL}/kiosk/my_reservations")
    req = Net::HTTP::Get.new(uri, { "Authorization" => "Bearer #{token}" })
    Kiosk::TestHelpers::Wire.http_for(uri).request(req).code.to_i
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
      detail: "REGRESSION: a self-asserted bearer was accepted over the wire — " \
              "#{forgeries.map(&:last).join("; ")} (want 401 for each)" }
  end
rescue StandardError => e
  { blocked: false, detail: "beat error: #{e.class}: #{e.message}" }
end

self_asserted_beat = self_asserted_token_forgery.call

# SelfAssertedUserBearerForgery: a self-asserted `user:u-<uuid>` bearer gets 401 at /kiosk/auth/link;
# a real Devise session is the control.
require "kiosk/user_identity_providers/devise_session"

self_asserted_user_bearer_forgery = lambda do
  anon = Kiosk::UserIdentityProviders::DeviseSession.new(BASE_URL)
  rc_forged, = anon.post_json(
    "/kiosk/auth/link", {}, { "Authorization" => "user:u-#{SecureRandom.uuid}" }
  )

  # Control: the honest channel still works.
  rider = Kiosk::UserIdentityProviders::DeviseSession.new(BASE_URL)
                       .sign_in!(email: RIDER_EMAIL, password: DEMO_PASSWORD)
  rc_real, = rider.post_json("/kiosk/auth/link", {}, { session: true })

  if rc_forged == 401 && [200, 201].include?(rc_real)
    { blocked: true,
      detail: "forged self-asserted `user:u-…` human bearer → 401 at /kiosk/auth/link in the " \
              "SAME env the drivers run in (no stub arm left); the real Devise session mints " \
              "a link code (#{rc_real}), so the refusal is not vacuous" }
  elsif rc_forged != 401
    { blocked: false,
      detail: "REGRESSION: forged self-asserted human bearer was accepted at " \
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

battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
{
  "MotorcycleForgedKyc"               => mc_beat,
  "MotorcycleViaStartRental"          => mc_verbswap_beat,
  "IssuedKycJwsTheft"                 => theft_beat,
  "CrossOperatorClaimReplay"          => xop_beat,
  "ForgedCallbackNoSig"               => fcb_beat,
  "UnregisteredVerbIsOrdinaryRefusal" => unregistered_verb_beat,
  "MethodMismatch"                    => method_mismatch_beat,
  "SelfAssertedTokenForgery"          => self_asserted_beat,
  "SelfAssertedUserBearerForgery"     => self_asserted_user_beat,
}.each { |name, beat| battery.record(name, beat[:blocked], beat[:detail]) }

# Exit 0 only when attacks ran and all were blocked; 2 when the skips are not EXPECTED_SKIP_NAMES.
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
