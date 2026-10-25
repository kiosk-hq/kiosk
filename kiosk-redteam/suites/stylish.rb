# frozen_string_literal: true

# Red-team battery for stylish: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-stylish with its bundle:
#   SERVER_URL=http://127.0.0.1:3005 bundle exec ruby ../kiosk-redteam/suites/stylish.rb

require 'date'
require 'json'
require 'time'
require 'securerandom'

require 'kiosk/redteam'

require 'kiosk/test_helpers/person'

# Booked slots are computed from today in UTC, so the controls never expire.
FUTURE_SLOT = lambda { |n, hour = 9|
  d = Date.today + 30 + n
  Time.utc(d.year, d.month, d.day, hour, 0, 0).iso8601
}
PAST_SLOT = '1900-01-01T09:00:00Z'

SERVER = ENV.fetch('SERVER_URL')

# Seeded accounts (db/seeds.rb); only the owner carries a staff_role.
OWNER_ID      = '00000000-0000-0000-0000-0000000000a0'
OWNER_EMAIL   = 'owner@combette.example'
ALICE_EMAIL   = 'alice@example.com'
BOB_EMAIL     = 'bob@example.com'
DEMO_PASSWORD = 'combette-demo-password'

# The owner's browser session, signed in once and reused by the beats below.
def owner_session
  @owner_session ||= Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
                                                                .sign_in!(email: OWNER_EMAIL, password: DEMO_PASSWORD)
end

# The assistants' calls; each solves the proof-of-work toll the operator asks.
WIRE = Kiosk::TestHelpers::Wire.new(base_url: SERVER, pay_tolls: true)

# The assistant side of the binding ceremonies: registration, client assertions, tokens.
ASSISTANT = Kiosk::TestHelpers::Assistant.new(base_url: SERVER)

# A newly registered client redeems a link code that `session`'s human mints;
# extra keys are smuggled into the claim body. Answers the claim's status, the
# token answer that follows it, and the client.
def claim_link(session, extra_claim_body = {})
  rc, link = session.post_json('/kiosk/auth/link', {}, { session: true })
  return [rc, {}, nil] unless rc == 201

  principal = ASSISTANT.register_client!
  body = { code: link.fetch('link_code'), client_assertion_type: ASSISTANT.class::ASSERTION_TYPE,
           client_assertion: ASSISTANT.client_assertion(principal) }.merge(extra_claim_body)
  rc = WIRE.post('/kiosk/auth/claim', body).status
  return [rc, {}, principal] unless rc == 204

  [rc, ASSISTANT.token(principal).body, principal]
end

BATTERY = Kiosk::Redteam::Battery.new

# Two customers' assistants, each linked to its seeded human's account.
ALICE = Kiosk::TestHelpers::Person.new(SERVER, email: ALICE_EMAIL, password: DEMO_PASSWORD).links_a_newcomer.principal
BOB   = Kiosk::TestHelpers::Person.new(SERVER, email: BOB_EMAIL,   password: DEMO_PASSWORD).links_a_newcomer.principal
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# Alice's appointment: the cross-tenant target.
rc, salons = WIRE.get_json('/kiosk/salons', {}, WIRE.dpop(ALICE.token, ALICE.key))
abort "salons query failed (#{rc}): #{JSON.generate(salons)} — run bin/rails db:reset" unless rc == 200
salon_id = Array(salons).first&.fetch('salon_id')
abort 'no salons seeded — run bin/rails db:reset' unless salon_id

rc, appt_a = WIRE.post_json(
  '/kiosk/book_appointment',
  { salon_id: salon_id, slot: FUTURE_SLOT.call(1) },
  WIRE.dpop(ALICE.token, ALICE.key)
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a)}" unless rc == 200
appt_id_a = appt_a['appointment_id']

# Bob books his own first, so each absence below has a positive control.
rc_b, bobs = WIRE.post_json(
  '/kiosk/book_appointment',
  { salon_id: salon_id, slot: FUTURE_SLOT.call(2, 10) },
  WIRE.dpop(BOB.token, BOB.key)
)
abort "B book_appointment failed (#{rc_b}): #{JSON.generate(bobs)}" unless rc_b == 200
appt_id_bob = bobs['appointment_id']

rc, b_appts = WIRE.get_json('/kiosk/my_appointments', {}, WIRE.dpop(BOB.token, BOB.key))
b_ids = Array(b_appts).map { |r| r['id'] }
b_sees_own = b_ids.include?(appt_id_bob)
BATTERY.record('CrossTenantRead',
               rc == 200 && b_sees_own && !b_ids.include?(appt_id_a),
               "B's my_appointments #{b_ids.inspect} carries B's OWN #{appt_id_bob.inspect} " \
               "(sees_own=#{b_sees_own}) and excludes A's #{appt_id_a}")

# Bob books with Alice's user_id: refused by additionalProperties: false.
rc, forged = WIRE.post_json(
  '/kiosk/book_appointment',
  { salon_id: salon_id, slot: FUTURE_SLOT.call(2), user_id: ALICE.user_id },
  WIRE.dpop(BOB.token, BOB.key)
)
refused = rc == 400 && forged['code'] == 'bad_request' && forged['detail'].to_s.include?('user_id')

# Bob's booking must not appear under Alice, whose own must.
rc_a, a_appts = WIRE.get_json('/kiosk/my_appointments', {}, WIRE.dpop(ALICE.token, ALICE.key))
a_ids = Array(a_appts).map { |r| r['id'] }
a_sees_own = a_ids.include?(appt_id_a)
BATTERY.record('ForgedUserId',
               refused && rc_a == 200 && a_sees_own && !a_ids.include?(appt_id_bob),
               "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
               "A's list #{a_ids.inspect} carries her OWN #{appt_id_a.inspect} " \
               "(sees_own=#{a_sees_own}) and excludes B's #{appt_id_bob.inspect}")

rc, = WIRE.get_json('/kiosk/salons')
BATTERY.record('MissingAuth', rc == 401, "unauthenticated request → #{rc} (want 401)")

rc, = WIRE.get_json('/kiosk/salons', {}, WIRE.dpop('not-a-real-token', ALICE.key))
BATTERY.record('GarbageToken', rc == 401, "garbage token → #{rc} (want 401)")

# A copied token without its key buys nothing: as a bearer token, or with another key's DPoP proof.
rc_stolen_bearer, = WIRE.get_json('/kiosk/salons', {}, 'Authorization' => "Bearer #{ALICE.token}")
rc_stolen_key,    = WIRE.get_json('/kiosk/salons', {}, WIRE.dpop(ALICE.token, BOB.key))
BATTERY.record('StolenToken', rc_stolen_bearer == 401 && rc_stolen_key == 401,
               "stolen token as a bearer → #{rc_stolen_bearer}, with the thief's key → #{rc_stolen_key} (want 401 both)")

rc, = WIRE.get_json('/kiosk/frobnicate', {}, WIRE.dpop(ALICE.token, ALICE.key))
BATTERY.record('UnknownQuery', rc == 404, "unknown query → #{rc} (want 404)")

rc, = WIRE.post_json('/kiosk/nope', {}, WIRE.dpop(ALICE.token, ALICE.key))
BATTERY.record('UnknownAction', rc == 404, "unknown action → #{rc} (want 404)")

# /kiosk/query and /kiosk/run route nowhere: a plain 404 with or without a bearer.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'salons' }, headers: WIRE.dpop(ALICE.token, ALICE.key))
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'salons' })
  [[authed.status == 404 && authed.body['code'].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body['code'].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record('UnregisteredVerbIsOrdinaryRefusal',
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               '(want a plain 404 with no problem-document code, bearer or not)')

# A GET at an action's path matches no route and never reaches the action.
res404 = WIRE.request(:get, '/kiosk/book_appointment', headers: WIRE.dpop(ALICE.token, ALICE.key))
BATTERY.record('MethodMismatch',
               res404.status == 404 && res404['allow'].nil? && res404.body['code'].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               '(want a plain 404, no Allow, no problem-document code)')

# Role escalation through the link ceremony: the role comes from the IdP session.

# A customer's own link mints, but binds at `customer`.
customer_session = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
                                                              .sign_in!(email: ALICE_EMAIL, password: DEMO_PASSWORD)
rc_cl, cust_token_answer = claim_link(customer_session)
cust_role = Kiosk::Redteam::TokenClaims.claims(cust_token_answer['access_token'])&.fetch('role', nil)
BATTERY.record('CustomerLinkCannotCarryOwnerRole',
               rc_cl == 204 && cust_role == 'customer',
               "customer link claim → #{rc_cl}, bound token role #{cust_role.inspect} " \
               '(want 204 + "customer"; the role is read off the human, never chosen)')

# A forged role in the claim body is ignored; the owner's IdP session sets the role.
rc, owner_token_answer, owner = claim_link(owner_session, role: 'superuser', allowed_roles: ['superuser'], requested_role: 'superuser')
owner_token = owner_token_answer['access_token'].to_s
role_claim = Kiosk::Redteam::TokenClaims.claims(owner_token)&.fetch('role', nil)
BATTERY.record('OwnerLinkIgnoresForgedClaimBody',
               rc == 204 && role_claim == 'owner',
               "owner link with forged claim body → claim #{rc}, token role #{role_claim.inspect} (want 204 + \"owner\", body ignored)")

# Alice's calendar excludes Bob's booking.
rc_b3, appt_b3 = WIRE.post_json(
  '/kiosk/book_appointment',
  { salon_id: salon_id, slot: FUTURE_SLOT.call(3) },
  WIRE.dpop(BOB.token, BOB.key)
)
appt_id_b3 = appt_b3['appointment_id']

rc, cal = WIRE.get_json('/kiosk/salon_calendar', {}, WIRE.dpop(ALICE.token, ALICE.key))
rows = Array(cal)
own_ids  = rows.map { |r| r['id'] }
# Positive control: an empty calendar would satisfy every absence.
sees_own = own_ids.include?(appt_id_a)
own_only = !own_ids.include?(appt_id_b3)
BATTERY.record('CustomerCalendarStaysOwnScoped',
               rc == 200 && rc_b3 == 200 && sees_own && own_only,
               "customer salon_calendar: #{rows.size} rows #{own_ids.inspect}, carries her OWN " \
               "#{appt_id_a.inspect} (sees_own=#{sees_own}), excludes B's #{appt_id_b3.inspect} " \
               "(own_only=#{own_only})")

# Role escalation through the device-grant ceremony (RFC 8628): the role is the approver's.

# The human approves `user_code` on the verify page; returns that page.
def approve_on_verify_page(session, user_code)
  page = session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
  form = { 'user_code' => user_code, 'decision' => 'approve' }
  csrf = session.csrf_token(page.body)
  form['authenticity_token'] = csrf if csrf
  session.post_form('/kiosk/oauth/device/verify', form)
  page
end

# The registered client opens a ceremony, `session`'s human approves it on the
# verify page, the client polls once; the first poll of a code solves the toll.
# Returns [authorization_http, poll_http, token_or_nil, verify_page_html].
def claim_ceremony(session, principal, **params)
  opened = ASSISTANT.device_authorization(principal, **params)
  return [opened.status, nil, nil, nil] unless opened.status == 200

  page = approve_on_verify_page(session, opened.body.fetch('user_code'))
  poll = ASSISTANT.device_token(opened.body.fetch('device_code'), principal)
  [opened.status, poll.status, (poll.body['access_token'] if poll.body.is_a?(Hash)), page.body]
end

# The unverified claims of a token, or {}.
def token_role(token) = Kiosk::Redteam::TokenClaims.claims(token) || {}

# The request opening the ceremony may not name a role, declared or not.
selfselect = ASSISTANT.register_client!
self_selection = [
  ['role=owner (DECLARED here — the escalation itself)', { 'role' => 'owner' }],
  ['role=customer (declared, no escalation — still not the client\'s to name)', { 'role' => 'customer' }],
  ['role=master (undeclared)', { 'role' => 'master' }]
].map do |label, params|
  rc, body = ASSISTANT.device_authorization(selfselect, **params).then { [it.status, it.body] }
  [rc == 400 && body['error'] == 'invalid_request', "#{label} → #{rc}/#{body['error'].inspect}"]
end

# Control: the same request without a role opens the ceremony.
rc_ctrl, da_ctrl = ASSISTANT.device_authorization(selfselect).then { [it.status, it.body] }
control_ok = rc_ctrl == 200 && da_ctrl['user_code'].to_s.match?(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
BATTERY.record('DeviceGrantCannotSelfSelectRole',
               self_selection.all? { |ok, _| ok } && control_ok,
               "#{self_selection.map(&:last).join('; ')}; CONTROL role-less request → #{rc_ctrl} " \
               "user_code=#{da_ctrl['user_code'].inspect} (want every role 400/invalid_request, " \
               'and the role-less ceremony still opening)')

# A customer's ceremony lands at `customer`, an owner's at `owner`, over the same endpoints.
# The customer's client asks for scope=owner: the operator ignores a scope.
cust = ASSISTANT.register_client!
_rc_a, rc_cust_poll, cust_token, cust_page = claim_ceremony(customer_session, cust, scope: 'owner')
cust_claim_role = token_role(cust_token)['role']
rc_cust_cal, cust_cal = WIRE.get_json('/kiosk/salon_calendar', {}, WIRE.dpop(cust_token, cust.key))
cust_rows      = Array(cust_cal)
# Positive control: the customer token reaches Alice's own booking.
cust_sees_own  = cust_rows.any? { |r| r['id'] == appt_id_a }
cust_own_only  = cust_rows.none? { |r| r['id'] == appt_id_b3 }

own = ASSISTANT.register_client!
_rc_o, rc_own_poll, own_claim_token, own_page = claim_ceremony(owner_session, own)
own_claim_role = token_role(own_claim_token)['role']
rc_own_cal, own_cal = WIRE.get_json('/kiosk/salon_calendar', {}, WIRE.dpop(own_claim_token, own.key))
own_rows        = Array(own_cal)
own_sees_others = own_rows.any? { |r| r['id'] == appt_id_b3 }

BATTERY.record('DeviceGrantRoleComesFromTheApprover',
               rc_cust_poll == 200 && cust_claim_role == 'customer' &&
                 rc_cust_cal == 200 && cust_sees_own && cust_own_only &&
                 rc_own_poll == 200 && own_claim_role == 'owner' &&
                 rc_own_cal == 200 && own_sees_others,
               "customer-approved claim that asked scope=owner → poll #{rc_cust_poll}, token role #{cust_claim_role.inspect}, " \
               "calendar #{rc_cust_cal} sees_own=#{cust_sees_own} own_only=#{cust_own_only}; " \
               "CONTROL owner-approved claim over the SAME endpoints → poll #{rc_own_poll}, token role " \
               "#{own_claim_role.inspect}, calendar #{rc_own_cal} whole_book=#{own_sees_others} " \
               "(want customer/own-scoped and owner/whole-book — the role is the approver's, never the caller's)")

# The verify page names the role it grants, and differs per approver.
cust_page_names  = cust_page.to_s.include?('Access you are handing it') &&
                   cust_page.to_s.include?('<code>customer</code>')
own_page_names   = own_page.to_s.include?('Access you are handing it') &&
                   own_page.to_s.include?('<code>owner</code>')
pages_differ     = !cust_page.to_s.include?('<code>owner</code>')
BATTERY.record('DeviceGrantVerifyPageNamesTheAccess',
               cust_page_names && own_page_names && pages_differ,
               "customer's verify page names `customer`: #{cust_page_names}; owner's names `owner`: " \
               "#{own_page_names}; the customer's page does NOT say owner: #{pages_differ} " \
               "(want all three — the field is the approver's real role, not a constant)")

# Re-running the ceremony with a bound client (rebind) still yields the approver's role.
rc_rebind_refused, rebind_refused_body = ASSISTANT.device_authorization(cust, 'role' => 'owner').then { [it.status, it.body] }
_rc_r, rc_rebind_poll, rebind_token, = claim_ceremony(customer_session, cust)
rebind_claims = token_role(rebind_token)
rebind_role   = rebind_claims['role']
rebind_stable = rebind_claims['agent_id'] == token_role(cust_token)['agent_id']
rc_rebind_cal, rebind_cal = WIRE.get_json('/kiosk/salon_calendar', {}, WIRE.dpop(rebind_token, cust.key))
rebind_rows      = Array(rebind_cal)
# Positive control: the rebound token still reads Alice's book.
rebind_sees_own  = rebind_rows.any? { |r| r['id'] == appt_id_a }
rebind_own_only  = rebind_rows.none? { |r| r['id'] == appt_id_b3 }
BATTERY.record('DeviceGrantRebindCannotEscalate',
               rc_rebind_refused == 400 && rebind_refused_body['error'] == 'invalid_request' &&
                 rc_rebind_poll == 200 && rebind_role == 'customer' && rebind_stable &&
                 rc_rebind_cal == 200 && rebind_sees_own && rebind_own_only,
               "bound client re-runs the ceremony: role=owner → #{rc_rebind_refused}/" \
               "#{rebind_refused_body['error'].inspect}; the honest re-run → poll #{rc_rebind_poll}, " \
               "role #{rebind_role.inspect}, agent_id stable=#{rebind_stable}, calendar #{rc_rebind_cal} " \
               "sees_own=#{rebind_sees_own} own_only=#{rebind_own_only} (want the rebind to stay " \
               "the approver's role, not one ceremony later's escalation)")

# An unsigned `agent:u-…:r-owner` bearer resolves to no identity; the owner's real token is the control.
forged_owner_bearer = WIRE.dpop("agent:u-#{OWNER_ID}:a-#{SecureRandom.uuid}:r-owner", ALICE.key)
rc_forged_cal, = WIRE.get_json('/kiosk/salon_calendar', {}, forged_owner_bearer)
rc_forged_book, = WIRE.post_json('/kiosk/book_appointment',
                                 { salon_id: salon_id, slot: FUTURE_SLOT.call(5) },
                                 forged_owner_bearer)
rc_owner_cal, owner_cal = WIRE.get_json('/kiosk/salon_calendar', {}, WIRE.dpop(owner_token, owner&.key))
owner_sees_book = Array(owner_cal).any? { |r| r['id'] == appt_id_b3 }
BATTERY.record('SelfAssertedTokenForgery',
               rc_forged_cal == 401 && rc_forged_book == 401 &&
                 rc_owner_cal == 200 && owner_sees_book,
               "self-asserted `agent:u-#{OWNER_ID}:a-…:r-owner` → salon_calendar #{rc_forged_cal}, " \
               "book_appointment #{rc_forged_book} (want 401/401: it resolves to NO identity, in THIS " \
               "environment — no env gate involved); CONTROL the owner's GENUINELY-BOUND token → " \
               "salon_calendar #{rc_owner_cal}, whole_book=#{owner_sees_book} (want 200/true, so " \
               'the refusal is about the bearer and not a closed endpoint)')

# A self-asserted X-Staff-Session header buys nothing; the owner's real session is the control.
self_asserted_staff_forgery = lambda do
  rc_forged, = WIRE.post_json('/kiosk/auth/link', {}, { 'X-Staff-Session' => OWNER_ID })
  rc_real, _link = owner_session.post_json('/kiosk/auth/link', {}, { session: true })

  blocked = rc_forged == 401 && rc_real == 201
  detail =
    if blocked
      'forged `X-Staff-Session` naming the owner → 401 at /kiosk/auth/link in the SAME env this ' \
        'suite drives (nothing anywhere reads the header); the ' \
        "owner's REAL Devise session still mints (201), so the refusal is not vacuous"
    elsif rc_forged != 401
      "REGRESSION: forged X-Staff-Session was accepted at /kiosk/auth/link (HTTP #{rc_forged})"
    else
      "unexpected: the owner's REAL Devise session was refused too (HTTP #{rc_real}) — the 401 " \
        'above proves nothing'
    end
  BATTERY.record('SelfAssertedStaffSessionForgery', blocked, detail)
rescue StandardError => e
  BATTERY.record('SelfAssertedStaffSessionForgery', false, "beat error: #{e.class}: #{e.message}")
end
self_asserted_staff_forgery.call

# Bad booking input is a typed 400 without PG internals, never a 500 or a silent booking.
BAD_INPUTS = [
  ['unparseable slot', { salon_id: :seeded, slot: 'banana' }],
  ['fuzzy slot (silent past booking)', { salon_id: :seeded, slot: 'next tuesday' }],
  ['empty slot',              { salon_id: :seeded, slot: '' }],
  ['missing slot',            { salon_id: :seeded }],
  ['non-string slot',         { salon_id: :seeded, slot: 12_345 }],
  ['out-of-range slot',       { salon_id: :seeded, slot: '2026-13-45T99:00:00Z' }],
  # Well-formed but past; the probes below carry a future slot so only their own field is wrong.
  ['past slot (well-formed, already gone)', { salon_id: :seeded, slot: PAST_SLOT }],
  ['unknown salon_id',        { salon_id: 999_999, slot: FUTURE_SLOT.call(1) }],
  ['missing salon_id',        { slot: FUTURE_SLOT.call(1) }],
  ['unknown service_id',      { salon_id: :seeded, slot: FUTURE_SLOT.call(1), service_id: 999_999 }]
].freeze
PG_INTERNALS = ['PG::', 'NotNullViolation', 'RecordInvalid', 'DatatypeMismatch', 'violates not-null'].freeze

bad_failures = []
BAD_INPUTS.each do |label, args|
  body = args.dup
  body[:salon_id] = salon_id if body[:salon_id] == :seeded
  rc, resp = WIRE.post_json('/kiosk/book_appointment', body, WIRE.dpop(ALICE.token, ALICE.key))
  code = resp.is_a?(Hash) ? resp['code'] : nil
  # `supplied:` keeps the probe's own echoed bytes from reading as a leak.
  scan = Kiosk::Redteam::LeakScan.scan(resp, PG_INTERNALS, supplied: body)
  next if rc == 400 && code == 'bad_request' && !scan.leak?

  bad_failures << "#{label} → HTTP #{rc} code=#{code.inspect}" \
                  "#{" LEAKS #{scan.leak.inspect}" if scan.leak}#{scan.note}" \
                  "#{' (SILENTLY BOOKED)' if rc == 200}"
end

# Positive controls: a bare and a priced booking still succeed.
rc_bare, bare = WIRE.post_json('/kiosk/book_appointment',
                               { salon_id: salon_id, slot: FUTURE_SLOT.call(3) }, WIRE.dpop(ALICE.token, ALICE.key))
bad_failures << "CONTROL bare salon booking → HTTP #{rc_bare} #{JSON.generate(bare)[0, 160]}" unless rc_bare == 200

rc_menu, menu = WIRE.get_json('/kiosk/service_menu', {}, WIRE.dpop(ALICE.token, ALICE.key))
service = Array(menu).find { |r| r['price_cents'].to_i.positive? }
rc_full, full = WIRE.post_json('/kiosk/book_appointment',
                               { salon_id: salon_id, slot: FUTURE_SLOT.call(4),
                                 service_id: service && service['service_id'] }, WIRE.dpop(ALICE.token, ALICE.key))
unless rc_menu == 200 && rc_full == 200 && full['price_cents'].to_i == service['price_cents'].to_i
  bad_failures << "CONTROL priced booking → HTTP #{rc_full} price_cents=#{full['price_cents'].inspect} " \
                  "(want #{service && service['price_cents'].inspect})"
end

BATTERY.record('UntypedBookingInput', bad_failures.empty?,
               bad_failures.empty? ? "#{BAD_INPUTS.size} bad-input shapes → typed 400 bad_request, no PG internals; bare + priced bookings still succeed" : bad_failures.join(' | '))

# The shared kiosk-redteam beat; this origin declares two roles, so a skip is a breach.
# The call toll holds against known bypasses: a new account solves a proof of work on every 10th call.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::CallToll.new,
  client: Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(
    tolled_calls_per_proof: 10, tolled_query: 'my_appointments',
    person: -> { Kiosk::TestHelpers::Person.new(SERVER, email: 'bob@example.com', password: 'combette-demo-password') }
  ),
  on_skip: :breach
)

BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client: Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer owner]),
  on_skip: :breach
)

# 0 only when every beat ran and was blocked; stylish expects no skips.
exit BATTERY.report!
