# frozen_string_literal: true

# Red-team battery for skooti: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-skooti with its bundle:
#   SERVER_URL=http://127.0.0.1:3004 bundle exec ruby ../kiosk-redteam/suites/skooti.rb

require 'kiosk/redteam'
require 'kiosk/user_identity_providers/devise_session'
require 'jwt'
require 'openssl'
require 'securerandom'
require 'net/http'
require 'uri'
require 'json'

# KYC attestations: valid/expired signed with the broker's key, forged with a wrong key under the trusted issuer.
require_relative '../support/prove_test_issuer'

BASE_URL = ENV.fetch('SERVER_URL')
ISSUER   = BASE_URL
# The KYC broker as the demo's development and test environments point this origin at it.
BROKER_URL     = 'http://127.0.0.1:3020'
TRUSTED_ISSUER = ProveTestIssuer.issuer
# The seeded rider (db/seeds.rb).
RIDER_EMAIL   = 'ada@example.com'
DEMO_PASSWORD = 'skooti-demo-password'

# Wrong key, trusted issuer: only the signature is bad.
FORGED_KYC_KEY = OpenSSL::PKey::RSA.generate(2048)

# The attributes a motorcycle rental asks for, spelled as the attestation carries them.
LICENCE_ATTRIBUTES = { 'age_over_18' => true, 'licence_a' => true }.freeze

def attest_forged(user_id)
  now = Time.now.to_i
  # Trusted issuer and correct audience: ONLY the signature is wrong.
  claims = { sub: user_id, level: 'verified', iss: TRUSTED_ISSUER, aud: ProveTestIssuer.audience,
             iat: now, exp: now + 3600 }
  JWT.encode(claims, FORGED_KYC_KEY, 'RS256')
end

# The broker's approval as the human gives it, and skooti's KYC callback reached directly.

def broker_approve(request_id)
  uri = URI("#{BROKER_URL}/verify")
  req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/x-www-form-urlencoded')
  req.body = URI.encode_www_form(request: request_id, decision: 'approve')
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  res.code.to_i
end

def post_kyc_callback(body)
  uri = URI("#{BASE_URL}/kiosk/kyc/callback")
  req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  req.body = JSON.generate(body)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  res.code.to_i
end

# The kyc_verification events this customer's stream replays from the start.
def kyc_events_for(customer)
  stream = Kiosk::TestHelpers::Assistant::Events.new(base_url: BASE_URL, token: customer.token)
  stream.subscribe('kyc_verification', since: 0)
  stream.listen(2)
ensure
  stream&.close
end

# An intent mandate capped at `cap`, and a one-line cart for `total`, as script/rental_flow.rb builds them.
def mobility_mandates(customer, line_item, total, cap)
  now       = Time.now.to_i
  intent_id = SecureRandom.uuid
  { intent: { id: intent_id, user_id: customer.user_id, agent_id: customer.agent_id, iss: ISSUER,
              scope: 'mobility', cap_amount_cents: cap, currency: 'eur', exp: now + 600, iat: now },
    cart: { id: SecureRandom.uuid, intent_mandate_id: intent_id, user_id: customer.user_id,
            agent_id: customer.agent_id, iss: ISSUER, line_items: [line_item],
            total_amount_cents: total, currency: 'eur', exp: now + 600, iat: now } }
end

# The quoted price of a reservation, or 100 when the quote is not positive.
def quoted_cents(price_per_min_cents)
  price = price_per_min_cents.to_i
  price.positive? ? price : 100
end

# The first licence-free vehicle no live reservation holds. A vehicle holds one
# reservation at a time, so every rider here reserves its own.
def free_scooter_code(client, customer)
  fleet = client.query(customer, name: 'scooters_available').body
  scooter = (fleet.is_a?(Array) ? fleet : []).find { |row| row['needs_licence'] == false }
  raise 'redteam(skooti): no licence-free vehicle is free in scooters_available' unless scooter

  scooter['code']
end

def body_field(resp, key)
  resp.body.is_a?(Hash) ? resp.body[key] : nil
end

# What a refusal report adds when the leak scan found something, or has a note.
def leak_note(scan)
  "#{" LEAKS #{scan.leak.inspect}" if scan.leak}#{scan.note}"
end

profile = Kiosk::Redteam::Profile.new(
  pow_difficulty: 20, # >0 turns the Equihash /register gate on; not an Equihash parameter
  requires_kyc: true, # rent_motorcycle is attribute-gated; start_rental refuses licence vehicles
  currency: 'eur',
  declared_roles: %w[customer],

  per_user_query: 'my_reservations',

  row_id_key: 'reservation_id',
  result_id_key: 'reservation_id',

  # Reserves a free licence-free scooter; reserve needs no KYC.
  create_owned: lambda { |client, customer|
    rsv_resp = client.run(customer, name: 'reserve', scooter_code: free_scooter_code(client, customer))
    raise "redteam(skooti): reserve failed (#{rsv_resp.status}): #{rsv_resp.body.inspect}" \
      unless rsv_resp.status == 200

    {
      id: rsv_resp.body['reservation_id'],
      price_per_min_cents: rsv_resp.body['price_per_min_cents'].to_i
    }
  },

  # reserve declares only scooter_code, so an injected user_id is a typed 400.
  forge_action: 'reserve',
  forge_args: ->(client, customer_a, _customer_b) { { scooter_code: free_scooter_code(client, customer_a) } },

  gated_action: 'start_rental',
  gated_args: ->(ref) { { reservation_id: ref[:id] } },

  pay_for: lambda { |_client, customer, owned_ref|
    total_cents = quoted_cents(owned_ref[:price_per_min_cents])
    mobility_mandates(customer, { qty: 1, price_cents: total_cents, reservation_id: owned_ref[:id] },
                      total_cents, total_cents + 100)
  },

  kyc_valid: ->(user_id) { ProveTestIssuer.attest(user_id: user_id) },
  kyc_expired: ->(user_id) { ProveTestIssuer.attest_expired(user_id: user_id) },
  kyc_forged: method(:attest_forged)
)

# skooti's own scenarios, run by the registry beside the library ones.
module SkootiScenarios
  # A fresh customer, the reservation it owns, and the mandates that pay for it.
  def self.paid_reservation(client, profile)
    customer = client.register!
    owned    = profile.create_owned.call(client, customer)
    [customer, owned, profile.pay_for.call(client, customer, owned)]
  end

  # Cashier checks on the agent's own reservation: the operator prices what lands on the counter.

  # A cart whose total is below the operator's quoted rental price must be rejected at capture.
  class TamperedPriceCart < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'TamperedPriceCart')
    end

    def call(client, profile)
      a, owned, m = SkootiScenarios.paid_reservation(client, profile)
      # The line matches the lowered total, so only the quote check can refuse it.
      lowered_total = quoted_cents(owned[:price_per_min_cents]) - 50
      m[:cart] = m[:cart].merge(
        line_items: [{ qty: 1, price_cents: lowered_total, reservation_id: owned[:id] }],
        total_amount_cents: lowered_total
      )
      resp = client.pay(a, intent: m[:intent], cart: m[:cart])
      # 403 by name: a 401 would mean the cashier never priced the cart.
      verdict_from(resp, expect: 403, detail: "below-quote total settled (HTTP #{resp.status})")
    end
  end

  # A cart whose total exceeds the sum of its line items must be rejected at capture.
  class InflatedTotalCart < Kiosk::Redteam::Scenario
    def initialize
      super(name: 'InflatedTotalCart')
    end

    def call(client, profile)
      a, owned, m = SkootiScenarios.paid_reservation(client, profile)
      # pay_for's single priced line sums to total_cents; inflate the total only.
      m[:cart] = m[:cart].merge(total_amount_cents: quoted_cents(owned[:price_per_min_cents]) + 50)
      resp = client.pay(a, intent: m[:intent], cart: m[:cart])
      # 403 by name — see TamperedPriceCart above.
      verdict_from(resp, expect: 403, detail: "total above the line-item sum settled (HTTP #{resp.status})")
    end
  end

  # A junk reservation_id — on start_rental, rent_motorcycle and inside a signed cart — is a typed 400
  # with no SQL internals; the cart probe reaches Kiosk::UuidCheck, which no input_schema covers.
  class MalformedUuidArg < Kiosk::Redteam::Scenario
    MALFORMED     = ['not-a-uuid', '1; DROP TABLE reservations', ''].freeze
    SQL_INTERNALS = ['::uuid', 'PG::', '22P02', 'invalid input syntax'].freeze

    def initialize
      super(name: 'MalformedUuidArg')
    end

    def call(client, _profile)
      a = licensed_customer(client)
      @failures = []
      @statuses = []
      MALFORMED.each { |junk| probe(client, a, junk) }
      check_control(client, a)

      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false,
                                  status: @statuses.find { |s| s != 400 } || 400, detail: @failures.join(' | '))
    end

    private

    # rent_motorcycle's attribute gate runs first; clear it so the uuid check is reached.
    def licensed_customer(client)
      a = client.register!
      kyc = client.kyc(a, attestation_jws: ProveTestIssuer.attest(user_id: a.user_id, attributes: LICENCE_ATTRIBUTES))
      raise "redteam(skooti): MalformedUuidArg fixture broken — /kyc returned #{kyc.status}" unless kyc.status == 200

      a
    end

    def probe(client, customer, junk)
      check("start_rental(#{junk.inspect})",
            client.run(customer, name: 'start_rental', reservation_id: junk), supplied: junk)
      check("rent_motorcycle(#{junk.inspect})",
            client.run(customer, name: 'rent_motorcycle', reservation_id: junk), supplied: junk)
      check("pay cart reservation_id=#{junk.inspect}",
            pay_with_ref(client, customer, junk), supplied: junk)
    end

    # Control: a well-formed unknown id must reach the cashier's 403, or the 400s above prove nothing.
    def check_control(client, customer)
      control = pay_with_ref(client, customer, '00000000-0000-4000-8000-000000000000')
      return if control.status == 403

      @failures << "CONTROL well-formed-but-unknown reservation_id → HTTP #{control.status} " \
                   "(want the cashier's 403; a 400 here means the malformed-uuid probes never reached the cashier)"
    end

    # supplied: the probe's own bytes, so an echoed value is not reported as a leak.
    def check(label, resp, supplied: nil)
      @statuses << resp.status
      scan = Kiosk::Redteam::LeakScan.scan(resp.body, SQL_INTERNALS, supplied: supplied)
      code = body_field(resp, 'code')
      return if resp.status == 400 && code == 'bad_request' && !scan.leak?

      @failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}#{leak_note(scan)}"
    end

    # Reserves nothing: the shape check runs before the cashier, so the shared fleet is untouched.
    def pay_with_ref(client, customer, junk)
      client.pay(customer, **mobility_mandates(customer, { qty: 1, price_cents: 100, reservation_id: junk }, 100, 200))
    end
  end

  # Non-string JSON shapes on every skooti argument are a typed 400; an unknown scooter_code reaches Reservation.create!.
  class HostileArgShapes < Kiosk::Redteam::Scenario
    LEAKS = ['::uuid', 'PG::', '22P02', 'invalid input syntax', 'NoMethodError',
             'TypeError', 'undefined method', 'ActiveRecord::'].freeze

    # The five families of hostile shape, as a string argument can carry them.
    SHAPES = [true, false, [], {}, ['SK-001'], { 'code' => 'SK-001' }, 1, 1.5].freeze

    # A value that spells three LEAKS, for the leak-scan control.
    ECHO_CONTROL = 'PG:: 22P02 invalid input syntax'

    def initialize
      super(name: 'HostileArgShapes')
    end

    def call(client, _profile)
      a         = client.register!
      @failures = []
      SHAPES.each { |v| probe_shape(client, a, v) }
      probe_unknown_vehicle(client, a)
      check_echo_control(client, a)
      check_reserve_control(client, a)

      Kiosk::Redteam::Verdict.new(blocked: @failures.empty?, skipped: false, status: 400,
                                  detail: @failures.join(' | '))
    end

    private

    # The one that reaches Reservation.create!: a well-typed but unknown handle.
    def probe_unknown_vehicle(client, customer)
      refused 'reserve scooter_code="NO-SUCH-VEHICLE"',
              client.run(customer, name: 'reserve', scooter_code: 'NO-SUCH-VEHICLE'),
              supplied: 'NO-SUCH-VEHICLE'
    end

    def probe_shape(client, customer, value)
      refused "reserve scooter_code=#{value.inspect}",
              client.run(customer, name: 'reserve', scooter_code: value), supplied: value
      refused "start_rental reservation_id=#{value.inspect}",
              client.run(customer, name: 'start_rental', reservation_id: value), supplied: value
      refused "rent_motorcycle reservation_id=#{value.inspect}",
              client.run(customer, name: 'rent_motorcycle', reservation_id: value), supplied: value
    end

    # Control for the leak scan: a needle `reserve` echoes back from the probe is not a leak.
    def check_echo_control(client, customer)
      echo_resp = client.run(customer, name: 'reserve', scooter_code: ECHO_CONTROL)
      refused 'reserve scooter_code=<a value spelling three LEAKS> (leak-scan control)',
              echo_resp, supplied: ECHO_CONTROL
      # Vacuous unless the refusal really echoed the value.
      return if JSON.generate(echo_resp.body).include?(ECHO_CONTROL)

      @failures << 'CONTROL VACUOUS: reserve did not echo the scooter_code it refused, so the ' \
                   'leak scan was never asked to tell an echo from a leak'
    end

    # Control: a real vehicle code still reserves.
    def check_reserve_control(client, customer)
      control = client.run(customer, name: 'reserve', scooter_code: free_scooter_code(client, customer))
      return if control.status == 200

      @failures << "CONTROL well-formed reserve → HTTP #{control.status} " \
                   "#{control.body.inspect[0, 90]} (want 200; the probes above prove nothing " \
                   'on an origin that refuses everything)'
    end

    # supplied: the probe's own bytes, so an echoed value is not reported as a leak.
    def refused(label, resp, supplied: nil)
      code = body_field(resp, 'code')
      scan = Kiosk::Redteam::LeakScan.scan(resp.body, LEAKS, supplied: supplied)
      return if resp.status == 400 && code == 'bad_request' && !scan.leak?

      @failures << "#{label} → HTTP #{resp.status} code=#{code.inspect}#{leak_note(scan)}"
    end
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
  Kiosk::Redteam::Scenarios::WrongCurrencyCart.new, # cashier check — currency
  SkootiScenarios::TamperedPriceCart.new,                # cashier check — below quote
  SkootiScenarios::InflatedTotalCart.new,                # cashier check — total ≠ line sum
  SkootiScenarios::MalformedUuidArg.new,                 # junk uuid → typed 400, no 500
  SkootiScenarios::HostileArgShapes.new # boolean/array/object/number shapes → typed 400
]

# skooti exposes the full surface: no library scenario may skip.
EXPECTED_SKIP_NAMES = [].freeze

puts "\n── skooti redteam battery ──"
puts "  base_url:              #{BASE_URL}"
puts '  register gate:         Equihash ' \
     "(profile pow_difficulty: #{profile.pow_difficulty} → RegistrationWithoutPow " \
     "#{profile.pow_difficulty.positive? ? %(applicable) : %(SKIPPED)})"
puts "  requires_kyc:          #{profile.requires_kyc}"
# The registry only; the local beats below are counted in the summary.
puts "  registered scenarios:  #{scenarios.size} (skooti-local beats run after them; the summary counts both)"
puts ''

runner  = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile:)
results = runner.run(scenarios)

# ── skooti-local beats: each answers { blocked:, detail: } ──

def new_customer
  client = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL)
  [client, client.register!]
end

# Reserves and pays for a vehicle, and answers its reservation_id.
def reserve_and_pay(client, customer, code)
  rsv = client.run(customer, name: 'reserve', scooter_code: code)
  raise "redteam(skooti): reserve #{code} failed (#{rsv.status})" unless rsv.status == 200

  reservation_id = rsv.body['reservation_id']
  total          = quoted_cents(rsv.body['price_per_min_cents'])
  line           = { qty: 1, price_cents: total, reservation_id: }
  pay_resp       = client.pay(customer, **mobility_mandates(customer, line, total, total + 100))
  raise "redteam(skooti): pay #{code} failed (#{pay_resp.status})" unless pay_resp.status == 200

  reservation_id
end

# The rider, with no attestation, who holds MC-001 reserved and paid, so only the
# KYC gate or the verb can block. MC-001 holds one reservation at a time, so
# every motorcycle beat attacks this one.
def motorcycle_rider
  @motorcycle_rider ||= begin
    client, a = new_customer
    [client, a, reserve_and_pay(client, a, 'MC-001')]
  end
end

def rent_refused?(rent)
  rent.status == 403 && body_field(rent, 'code') == 'kyc_required'
end

# Self-asserts both licence attributes, signed with the wrong key.
def forged_licence_jws(customer)
  now = Time.now.to_i
  claims = { sub: customer.user_id, level: 'verified', iss: TRUSTED_ISSUER,
             aud: ProveTestIssuer.audience, iat: now, exp: now + 3600, attributes: LICENCE_ATTRIBUTES }
  JWT.encode(claims, FORGED_KYC_KEY, 'RS256')
end

# MotorcycleForgedKyc: wrong-key licence attributes must not unlock rent_motorcycle.
def motorcycle_forged_kyc
  client, a, reservation_id = motorcycle_rider
  kyc_resp = client.kyc(a, attestation_jws: forged_licence_jws(a))
  # Decisive: rent_motorcycle is still refused.
  rent = client.run(a, name: 'rent_motorcycle', reservation_id:)
  forged_kyc_verdict(kyc_resp, rent)
end

def forged_kyc_verdict(kyc_resp, rent)
  if !rent_refused?(rent)
    { blocked: false, detail: "forged KYC unlocked the motorcycle: /kyc=#{kyc_resp.status}, rent_motorcycle=#{rent.status}" }
  elsif Kiosk::Redteam.blocked?(kyc_resp)
    { blocked: true, detail: "forged attestation rejected at /kyc (#{kyc_resp.status}); rent_motorcycle stays 403 kyc_required" }
  else
    # /kyc accepted it but no attributes were granted → still safe, still BLOCKED.
    { blocked: true, detail: 'forged attestation not granted; rent_motorcycle stays 403 kyc_required' }
  end
end

# MotorcycleViaStartRental: a paid MC-001 reservation cannot be activated with the scooter verb;
# the same sequence on a licence-free scooter is the control.
def motorcycle_via_start_rental
  client, a, reservation_id = motorcycle_rider
  # THE ATTACK — motorcycle reservation, scooter verb, no attestation anywhere.
  attack = client.run(a, name: 'start_rental', reservation_id:)
  # THE CONTROL — same agent, same sequence, licence-free vehicle.
  control = client.run(a, name: 'start_rental', reservation_id: reserve_and_pay(client, a, free_scooter_code(client, a)))
  verb_swap_verdict(attack, control)
end

def verb_swap_verdict(attack, control)
  breach = verb_swap_breach(attack)
  return { blocked: false, detail: breach } if breach

  unless control.status == 200 && !body_field(control, 'rental_token').to_s.empty?
    return { blocked: false,
             detail: "CONTROL FAILED: start_rental on a licence-free scooter returned HTTP #{control.status} with no token — " \
                     'the MC-001 refusal proves nothing (the verb, the payment or the harness is broken)' }
  end

  { blocked: true,
    detail: "start_rental refuses the KYC-gated MC-001 (HTTP #{attack.status} #{body_field(attack, 'code').inspect}), no rental_token; " \
            "control: a licence-free scooter still unlocks (HTTP #{control.status})" }
end

# Why the attack got through, or nil. A typed refusal must also name rent_motorcycle.
def verb_swap_breach(attack)
  token = body_field(attack, 'rental_token')
  return refusal_breach(attack) if token.to_s.empty?

  'start_rental issued an unlock token for the KYC-GATED MC-001 to an agent with no attestation ' \
    "(HTTP #{attack.status}, token #{token.to_s[0, 32]}…) — the licence gate was walked around by verb"
end

# Why a refusal with no token is still wrong, or nil.
def refusal_breach(attack)
  err = body_field(attack, 'code')
  if !([400, 403].include?(attack.status) && %w[bad_request forbidden kyc_required].include?(err))
    "start_rental on MC-001 answered HTTP #{attack.status} code=#{err.inspect} — no token, but not a typed client-error refusal either"
  elsif !JSON.generate(attack.body).include?('rent_motorcycle')
    "start_rental on MC-001 refused (HTTP #{attack.status} #{err.inspect}) but never names rent_motorcycle — " \
      "an assistant is left with no completable path, and this may not even be the licence gate: #{JSON.generate(attack.body)}"
  end
end

def request_kyc!(client, customer, tag)
  req = client.run(customer, name: 'request_kyc')
  raise "redteam(skooti): request_kyc(#{tag}) failed (#{req.status})" unless req.status == 200

  req.body['request_id']
end

# Victim B gets a real broker-signed jws through request_kyc and the broker page.
def issued_victim_jws(client)
  b = client.register!
  stream_b = Kiosk::TestHelpers::Assistant::Events.new(base_url: BASE_URL, token: b.token)
  stream_b.subscribe('kyc_verification')
  request_id = request_kyc!(client, b, 'B')
  approve_rc = broker_approve(request_id)
  raise "redteam(skooti): approve(B) on broker failed (#{approve_rc})" unless approve_rc == 200

  victim_jws = stream_b.await { |e| e.dig('data', 'request_id') == request_id }.dig('data', 'kyc_jws')
  stream_b.close
  victim_jws.to_s.empty? ? raise("redteam(skooti): B's kyc_verification event carried no jws") : victim_jws
end

# IssuedKycJwsTheft: B's broker-signed jws, submitted by A, must not unlock A's motorcycle.
def kyc_jws_theft
  # Attacker A holds its OWN paid motorcycle, so ONLY the KYC gate can block.
  client, a, reservation_id = motorcycle_rider
  victim_jws = issued_victim_jws(client)
  # A submits B's issued jws — the subject-binding must reject it.
  kyc_resp = client.kyc(a, attestation_jws: victim_jws)
  theft_verdict(kyc_resp, client.run(a, name: 'rent_motorcycle', reservation_id:))
end

def theft_verdict(kyc_resp, rent)
  if !rent_refused?(rent)
    { blocked: false, detail: "stolen jws unlocked A's motorcycle: /kyc=#{kyc_resp.status}, rent_motorcycle=#{rent.status}" }
  elsif Kiosk::Redteam.blocked?(kyc_resp)
    { blocked: true, detail: "B's issued jws rejected for A at /kyc (#{kyc_resp.status}); A's rent_motorcycle stays 403 kyc_required" }
  else
    { blocked: true, detail: "B's issued jws not granted to A; rent_motorcycle stays 403 kyc_required" }
  end
end

# A broker-shaped callback claim for `operator`, signed with `key`; the nonce is not under test.
def callback_jws(customer, request_id, operator, key)
  now = Time.now.to_i
  claims = { sub: customer.user_id, level: 'verified', iss: ProveTestIssuer.issuer,
             operator:, aud: operator, request_id:, nonce: 'any', iat: now, exp: now + 3600,
             attributes: LICENCE_ATTRIBUTES }
  JWT.encode(claims, key, 'RS256')
end

# CrossOperatorClaimReplay: a claim addressed to another operator is refused at skooti's callback and at the engine wire.
def cross_operator_replay
  client, a = new_customer
  # Open a real skooti request so the callback correlates to a pending row.
  request_id = request_kyc!(client, a, 'xop')
  # Signed with the broker key but addressed to another operator.
  jws = callback_jws(a, request_id, 'other-operator', ProveTestIssuer.keypair)
  # The callback must reject (403/404), so no attestation reaches the agent.
  cb_rc  = post_kyc_callback(request_id:, kyc_jws: jws, nonce: 'any')
  events = kyc_events_for(a)
  # The engine's aud check must refuse it alone, with the callback bypassed.
  cross_operator_verdict(cb_rc, events, client.kyc(a, attestation_jws: jws))
end

def cross_operator_verdict(cb_rc, events, wire_resp)
  if !Kiosk::Redteam.blocked?(wire_resp)
    { blocked: false, detail: "ENGINE BREACH: wrong-aud claim accepted at the wire (POST /kiosk/agents/kyc=#{wire_resp.status})" }
  elsif cb_rc != 200 && events.empty?
    { blocked: true, detail: "cross-operator claim rejected at BOTH the engine wire (POST /kiosk/agents/kyc → #{wire_resp.status}, aud mismatch) and /kyc/callback (#{cb_rc}); no kyc_verification event sent" }
  else
    { blocked: false, detail: "cross-operator claim accepted at the callback: callback=#{cb_rc}, kyc_verification events=#{events.size}" }
  end
end

# ForgedCallbackNoSig: a callback with a wrong-key jws, or none, is refused and emits no event.
def forged_callback_no_sig
  client, a = new_customer
  request_id = request_kyc!(client, a, 'fcb')
  # Wrong key, trusted issuer, addressed to skooti — ONLY the signature is bad.
  wrong_key_jws = callback_jws(a, request_id, ProveTestIssuer.audience, FORGED_KYC_KEY)
  cb_wrong = post_kyc_callback(request_id:, kyc_jws: wrong_key_jws, nonce: 'any')
  # Also a callback with NO jws at all.
  cb_missing = post_kyc_callback(request_id:, nonce: 'any')
  forged_callback_verdict(cb_wrong, cb_missing, kyc_events_for(a))
end

def forged_callback_verdict(cb_wrong, cb_missing, events)
  if cb_wrong != 200 && cb_missing != 200 && events.empty?
    { blocked: true, detail: "wrong-key callback (#{cb_wrong}) and no-jws callback (#{cb_missing}) both rejected; no kyc_verification event sent" }
  else
    { blocked: false, detail: "forged callback accepted: wrong=#{cb_wrong}, missing=#{cb_missing}, kyc_verification events=#{events.size}" }
  end
end

# A raw request the Client will not construct; bearer: false asks whether a credential changes the answer.
def raw_wire(customer, method, path, body = nil, bearer: true)
  uri     = URI("#{BASE_URL}#{path}")
  headers = { 'Content-Type' => 'application/json' }
  headers['Authorization'] = "Bearer #{customer.token}" if bearer
  req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
  req.body = JSON.generate(body) if body
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res, parsed_body(res)]
end

def parsed_body(res)
  JSON.parse(res.body)
rescue StandardError
  {}
end

# The answer to a list of [ok, line] probes: blocked when every probe is ok.
def probes_verdict(probes, blocked_detail, breach_detail)
  if probes.all? { |ok, _| ok }
    { blocked: true, detail: blocked_detail }
  else
    { blocked: false, detail: breach_detail }
  end
end

# POST /kiosk/query and /kiosk/run route nowhere: a plain 404, bearer or not, with no problem document.
def unregistered_verb(customer)
  probes = %w[query run].product([[true, ''], [false, ' (anon)']]).map do |name, (bearer, tag)|
    unregistered_verb_probe(customer, name, bearer, tag)
  end
  probes_verdict(probes,
                 "unregistered verb names #{probes.map(&:last).join(', ')} " \
                 '(the ordinary 404 any undrawn path gets, bearer or not, ' \
                 'and no privileged surface either way)',
                 'an unregistered verb name answers the wrong thing: ' \
                 "#{probes.reject { |ok, _| ok }.map(&:last).join(', ')}")
end

def unregistered_verb_probe(customer, name, bearer, tag)
  res, body = raw_wire(customer, :post, "/kiosk/#{name}", { name: 'scooters_available' }, bearer: bearer)
  [res.code.to_i == 404 && body['code'].nil?,
   "POST /kiosk/#{name}#{tag} → #{res.code}/#{body['code'].inspect} (want 404 with no problem-document code)"]
end

# MethodMismatch: the wrong method at a verb's path is a plain 404 with no Allow, both directions.
def method_mismatch(customer)
  probes = [
    [:get,  '/kiosk/reserve',         nil],
    [:post, '/kiosk/my_reservations', {}]
  ].map { |method, path, body| method_mismatch_probe(customer, method, path, body) }
  lines = probes.map(&:last).join('; ')
  probes_verdict(probes,
                 "the wrong method on a real verb draws no route and never runs it: #{lines}",
                 "a method mismatch is not answered as a plain 404: #{lines}")
end

def method_mismatch_probe(customer, method, path, body)
  res, doc = raw_wire(customer, method, path, body)
  ok = res.code.to_i == 404 && res['allow'].nil? && doc['code'].nil?
  [ok, "#{method.to_s.upcase} #{path} → #{res.code}/#{doc['code'].inspect} " \
       "Allow=#{res['allow'].inspect} (want a plain 404, no Allow, no code)"]
end

def bearer_status(token)
  uri = URI("#{BASE_URL}/kiosk/my_reservations")
  req = Net::HTTP::Get.new(uri, { 'Authorization' => "Bearer #{token}" })
  Kiosk::TestHelpers::Wire.http_for(uri).request(req).code.to_i
end

# SelfAssertedTokenForgery: a self-asserted agent bearer, even naming a real account as owner,
# resolves to no identity; the real token, paying its toll, is the control.
def self_asserted_token_forgery(customer)
  forgeries = forged_agent_bearers(customer).map do |label, token|
    code = bearer_status(token)
    [code == 401, "#{label} → #{code}"]
  end

  control = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL).query(customer, name: 'my_reservations')
  token_forgery_verdict(forgeries, control.status)
rescue StandardError => e
  { blocked: false, detail: "beat error: #{e.class}: #{e.message}" }
end

def forged_agent_bearers(customer)
  [['real account + real agent, role escalated to owner',
    "agent:u-#{customer.user_id}:a-#{customer.agent_id}:r-owner"],
   ['wholly invented ids', "agent:u-#{SecureRandom.uuid}:a-#{SecureRandom.uuid}:r-owner"]]
end

def token_forgery_verdict(forgeries, control_status)
  lines = forgeries.map(&:last).join('; ')
  return { blocked: false, detail: vacuous_control_detail('registered token', control_status) } if control_status != 200
  return { blocked: false, detail: "REGRESSION: a self-asserted bearer was accepted over the wire — #{lines} (want 401 for each)" } unless forgeries.all? { |ok, _| ok }

  { blocked: true,
    detail: "self-asserted `agent:u-…:r-owner` bearer resolves to NO identity — #{lines} — in the " \
            'SAME local env the drivers run in, with no environment condition in the ' \
            "assertion; the real registered token answers the same verb #{control_status}, so " \
            'the refusal is not vacuous' }
end

# The verdict detail when the honest control was refused too.
def vacuous_control_detail(control, status)
  "unexpected: the REAL #{control} was refused too (HTTP #{status}) — the refusals above prove nothing"
end

# SelfAssertedUserBearerForgery: a self-asserted `user:u-<uuid>` bearer gets 401 at /kiosk/auth/link;
# a real Devise session is the control.
def self_asserted_user_bearer_forgery
  anon = Kiosk::UserIdentityProviders::DeviseSession.new(BASE_URL)
  rc_forged, = anon.post_json(
    '/kiosk/auth/link', {}, { 'Authorization' => "user:u-#{SecureRandom.uuid}" }
  )

  # Control: the honest channel still works.
  rider = Kiosk::UserIdentityProviders::DeviseSession.new(BASE_URL)
                                                     .sign_in!(email: RIDER_EMAIL, password: DEMO_PASSWORD)
  rc_real, = rider.post_json('/kiosk/auth/link', {}, { session: true })
  user_bearer_verdict(rc_forged, rc_real)
rescue StandardError => e
  { blocked: false, detail: "beat error: #{e.class}: #{e.message}" }
end

def user_bearer_verdict(rc_forged, rc_real)
  return { blocked: false, detail: "REGRESSION: forged self-asserted human bearer was accepted at /kiosk/auth/link (HTTP #{rc_forged})" } if rc_forged != 401
  return { blocked: false, detail: vacuous_control_detail('Devise session', rc_real) } unless [200, 201].include?(rc_real)

  { blocked: true,
    detail: 'forged self-asserted `user:u-…` human bearer → 401 at /kiosk/auth/link in the ' \
            'SAME env the drivers run in (no stub arm left); the real Devise session mints ' \
            "a link code (#{rc_real}), so the refusal is not vacuous" }
end

beats = {
  'MotorcycleForgedKyc' => motorcycle_forged_kyc,
  'MotorcycleViaStartRental' => motorcycle_via_start_rental,
  'IssuedKycJwsTheft' => kyc_jws_theft,
  'CrossOperatorClaimReplay' => cross_operator_replay,
  'ForgedCallbackNoSig' => forged_callback_no_sig
}

# The wire-shape beats share one customer; neither touches the fleet.
wire_probe = Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL).register!
beats['UnregisteredVerbIsOrdinaryRefusal'] = unregistered_verb(wire_probe)
beats['MethodMismatch'] = method_mismatch(wire_probe)
beats['SelfAssertedTokenForgery'] = self_asserted_token_forgery(wire_probe)
beats['SelfAssertedUserBearerForgery'] = self_asserted_user_bearer_forgery

battery = Kiosk::Redteam::Battery.new
battery.absorb(results)
beats.each { |name, beat| battery.record(name, beat[:blocked], beat[:detail]) }

# Exit 0 only when attacks ran and all were blocked; 2 when the skips are not EXPECTED_SKIP_NAMES.
exit battery.report!(expected_skips: EXPECTED_SKIP_NAMES)
