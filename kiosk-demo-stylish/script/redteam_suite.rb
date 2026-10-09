# frozen_string_literal: true

# Red-team battery for stylish: attacks a running server and asserts every attack is refused.
# Usage: SERVER_URL=http://127.0.0.1:3005 bundle exec ruby script/redteam_suite.rb

require "date"
require "json"
require "net/http"
require "time"
require "uri"
require "jwt"
require "openssl"
require "securerandom"
require "base64"

require "kiosk/redteam"

require_relative "bound_assistant"
require "kiosk/user_identity_providers/devise_session"

# Booked slots are computed from today in UTC, so the controls never expire.
FUTURE_SLOT = lambda { |n, hour = 9|
  d = Date.today + 30 + n
  Time.utc(d.year, d.month, d.day, hour, 0, 0).iso8601
}
PAST_SLOT = "1900-01-01T09:00:00Z"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = SERVER

# Seeded accounts (db/seeds.rb); only the owner carries a staff_role.
OWNER_ID      = "00000000-0000-0000-0000-0000000000a0"
OWNER_EMAIL   = "owner@combette.example"
ALICE_EMAIL   = "alice@example.com"
BOB_EMAIL     = "bob@example.com"
DEMO_PASSWORD = "combette-demo-password"

# The owner's browser session, signed in once and reused by the beats below.
def owner_session
  @owner_session ||= Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
                                  .sign_in!(email: OWNER_EMAIL, password: DEMO_PASSWORD)
end

WIRE = Kiosk::TestHelpers::Wire.new(base_url: SERVER)

def pop_proof(key, pem)
  _rc, ch = WIRE.get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

# Links an owner's real Devise session; extra keys are smuggled into the claim body.
def link_as_owner(extra_claim_body = {})
  rc, link = owner_session.post_json("/kiosk/auth/link", {}, { session: true })
  return [rc, link] unless rc == 201

  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem
  WIRE.post_json("/kiosk/auth/claim",
                 { code: link.fetch("link_code"), public_key: pem, signed: pop_proof(key, pem) }.merge(extra_claim_body))
end

BATTERY = Kiosk::Redteam::Battery.new

# Two customer principals, bound through the shipped ceremony.
ALICE = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: DEMO_PASSWORD)
BOB   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: DEMO_PASSWORD)
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# Alice's appointment: the cross-tenant target.
rc, salons = WIRE.get_json("/kiosk/salons", {}, ALICE.bearer)
abort "salons query failed (#{rc}): #{JSON.generate(salons)} — run bin/rails db:reset" unless rc == 200
salon_id = Array(salons).first&.fetch("salon_id")
abort "no salons seeded — run bin/rails db:reset" unless salon_id

rc, appt_a = WIRE.post_json(
       "/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(1) },
       ALICE.bearer,
     )
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a)}" unless rc == 200
appt_id_a = appt_a["appointment_id"]

# Bob books his own first, so each absence below has a positive control.
rc_b, bobs = WIRE.post_json(
       "/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(2, 10) },
       BOB.bearer,
     )
abort "B book_appointment failed (#{rc_b}): #{JSON.generate(bobs)}" unless rc_b == 200
appt_id_bob = bobs["appointment_id"]

rc, b_appts = WIRE.get_json("/kiosk/my_appointments", {}, BOB.bearer)
b_ids = Array(b_appts).map { |r| r["id"] }
b_sees_own = b_ids.include?(appt_id_bob)
BATTERY.record("CrossTenantRead",
               rc == 200 && b_sees_own && !b_ids.include?(appt_id_a),
               "B's my_appointments #{b_ids.inspect} carries B's OWN #{appt_id_bob.inspect} " \
               "(sees_own=#{b_sees_own}) and excludes A's #{appt_id_a}")

# Bob books with Alice's user_id: refused by additionalProperties: false.
rc, forged = WIRE.post_json(
       "/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(2), user_id: ALICE.user_id },
       BOB.bearer,
     )
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("user_id")

# Bob's booking must not appear under Alice, whose own must.
rc_a, a_appts = WIRE.get_json("/kiosk/my_appointments", {}, ALICE.bearer)
a_ids = Array(a_appts).map { |r| r["id"] }
a_sees_own = a_ids.include?(appt_id_a)
BATTERY.record("ForgedUserId",
               refused && rc_a == 200 && a_sees_own && !a_ids.include?(appt_id_bob),
               "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
               "A's list #{a_ids.inspect} carries her OWN #{appt_id_a.inspect} " \
               "(sees_own=#{a_sees_own}) and excludes B's #{appt_id_bob.inspect}")

rc, _ = WIRE.get_json("/kiosk/salons")
BATTERY.record("MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

rc, _ = WIRE.get_json("/kiosk/salons", {}, WIRE.bearer("not-a-real-token"))
BATTERY.record("GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

rc, _ = WIRE.get_json("/kiosk/frobnicate", {}, ALICE.bearer)
BATTERY.record("UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

rc, _ = WIRE.post_json("/kiosk/nope", {}, ALICE.bearer)
BATTERY.record("UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# /kiosk/query and /kiosk/run route nowhere: a plain 404 with or without a bearer.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: "salons" }, headers: ALICE.bearer)
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: "salons" })
  [[authed.status == 404 && authed.body["code"].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body["code"].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record("UnregisteredVerbIsOrdinaryRefusal",
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               "(want a plain 404 with no problem-document code, bearer or not)")

# A GET at an action's path matches no route and never reaches the action.
res404 = WIRE.request(:get, "/kiosk/book_appointment", headers: ALICE.bearer)
BATTERY.record("MethodMismatch",
               res404.status == 404 && res404["allow"].nil? && res404.body["code"].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               "(want a plain 404, no Allow, no problem-document code)")

# Role escalation through the link ceremony: the role comes from the IdP session.

# A customer's own link mints, but binds at `customer`.
customer_session = Kiosk::UserIdentityProviders::DeviseSession.new(SERVER)
                                .sign_in!(email: ALICE_EMAIL, password: DEMO_PASSWORD)
rc_cl, link_cl = customer_session.post_json("/kiosk/auth/link", {}, { session: true })
cust_role = nil
if rc_cl == 201
  ck = OpenSSL::PKey::RSA.generate(2048)
  cpem = ck.public_key.to_pem
  _rc, cclaimed = WIRE.post_json("/kiosk/auth/claim",
                                 { code: link_cl.fetch("link_code"), public_key: cpem,
                                   signed: pop_proof(ck, cpem) })
  cseg = cclaimed["access_token"].to_s.split(".")[1].to_s
  cust_role = (JSON.parse(Base64.urlsafe_decode64(cseg + "=" * ((4 - cseg.length % 4) % 4)))["role"] rescue nil)
end
BATTERY.record("CustomerLinkCannotCarryOwnerRole",
               rc_cl == 201 && cust_role == "customer",
               "customer link mint → #{rc_cl}, bound token role #{cust_role.inspect} " \
               "(want 201 + \"customer\"; the role is read off the human, never chosen)")

# A forged role in the claim body is ignored; the owner's IdP session sets the role.
rc, claimed = link_as_owner(role: "superuser", allowed_roles: ["superuser"], requested_role: "superuser")
owner_token = claimed["access_token"].to_s
seg = owner_token.split(".")[1].to_s
role_claim = (JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))["role"] rescue nil)
BATTERY.record("OwnerLinkIgnoresForgedClaimBody",
               rc == 201 && role_claim == "owner",
               "owner link with forged claim body → token role #{role_claim.inspect} (want \"owner\", body ignored)")

# Alice's calendar excludes Bob's booking (`kind` is stamped on every row, so it proves nothing).
rc_b3, appt_b3 = WIRE.post_json(
       "/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(3) },
       BOB.bearer,
     )
appt_id_b3 = appt_b3["appointment_id"]

rc, cal = WIRE.get_json("/kiosk/salon_calendar", {}, ALICE.bearer)
rows = Array(cal)
own_ids     = rows.reject { |r| r["summary"] }.map { |r| r["id"] }
# Positive control: an empty calendar would satisfy every absence.
sees_own    = own_ids.include?(appt_id_a)
own_only    = !own_ids.include?(appt_id_b3)
no_forecast = rows.none? { |r| r["summary"] == "forecast" }
BATTERY.record("CustomerCalendarStaysOwnScoped",
               rc == 200 && rc_b3 == 200 && sees_own && own_only && no_forecast,
               "customer salon_calendar: #{rows.size} rows #{own_ids.inspect}, carries her OWN " \
               "#{appt_id_a.inspect} (sees_own=#{sees_own}), excludes B's #{appt_id_b3.inspect} " \
               "(own_only=#{own_only}), forecast_hidden=#{no_forecast}")

# Role escalation through the device-grant ceremony (RFC 8628): the role is the approver's.

DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

# The OAuth endpoints are form-encoded.
def oauth_post(path, form)
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri)
  req.set_form_data(form)
  res = Kiosk::TestHelpers::Wire.http_for(uri).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Open a ceremony, approve it on the verify page as `session`'s human, poll once.
# Returns [authorization_http, poll_http, token_or_nil, verify_page_html].
def claim_ceremony(session, key, pem, extra = {})
  rc, da = oauth_post("/kiosk/oauth/device_authorization",
                      { "client_id" => "redteam-claim", "public_key" => pem }.merge(extra))
  return [rc, nil, nil, nil] unless rc == 200

  user_code = da.fetch("user_code")
  page = session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
  form = { "user_code" => user_code, "decision" => "approve" }
  csrf = session.csrf_token(page.body)
  form["authenticity_token"] = csrf if csrf
  session.post_form("/kiosk/oauth/device/verify", form)

  rc_poll, tok = oauth_post("/kiosk/oauth/token",
                            { "grant_type" => DEVICE_GRANT,
                              "device_code" => da.fetch("device_code"),
                              "signed" => pop_proof(key, pem) })
  [rc, rc_poll, (tok["access_token"] if tok.is_a?(Hash)), page.body]
end

def token_role(token)
  seg = token.to_s.split(".")[1].to_s
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
rescue StandardError
  {}
end

# The request opening the ceremony may not name a role, declared or not.
self_selection = [
  ['role=owner (DECLARED here — the escalation itself)', { "role" => "owner" }],
  ['scope=owner (the OAuth-standard spelling of the same)', { "scope" => "owner" }],
  ['role=customer (declared, no escalation — still not the client\'s to name)', { "role" => "customer" }],
  ['role=master (undeclared)', { "role" => "master" }],
].map do |label, params|
  fresh = OpenSSL::PKey::RSA.generate(2048)
  rc, body = oauth_post("/kiosk/oauth/device_authorization",
                        { "client_id" => "redteam-selfselect",
                          "public_key" => fresh.public_key.to_pem }.merge(params))
  [rc == 400 && body["error"] == "invalid_request", "#{label} → #{rc}/#{body['error'].inspect}"]
end

# Control: the same request without a role opens the ceremony.
control_key = OpenSSL::PKey::RSA.generate(2048)
rc_ctrl, da_ctrl = oauth_post("/kiosk/oauth/device_authorization",
                              { "client_id" => "redteam-selfselect",
                                "public_key" => control_key.public_key.to_pem })
control_ok = rc_ctrl == 200 && da_ctrl["user_code"].to_s.match?(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
BATTERY.record("DeviceGrantCannotSelfSelectRole",
               self_selection.all? { |ok, _| ok } && control_ok,
               "#{self_selection.map(&:last).join('; ')}; CONTROL role-less request → #{rc_ctrl} " \
               "user_code=#{da_ctrl['user_code'].inspect} (want every role/scope 400/invalid_request, " \
               "and the role-less ceremony still opening)")

# A customer's ceremony lands at `customer`, an owner's at `owner`, over the same endpoints.
cust_key  = OpenSSL::PKey::RSA.generate(2048)
cust_pem  = cust_key.public_key.to_pem
_rc_a, rc_cust_poll, cust_token, cust_page = claim_ceremony(customer_session, cust_key, cust_pem)
cust_claim_role = token_role(cust_token)["role"]
rc_cust_cal, cust_cal = WIRE.get_json("/kiosk/salon_calendar", {}, WIRE.bearer(cust_token))
cust_rows      = Array(cust_cal)
# Positive control: the customer token reaches Alice's own booking.
cust_sees_own  = cust_rows.any? { |r| r["id"] == appt_id_a }
cust_own_only  = cust_rows.none? { |r| r["id"] == appt_id_b3 }
cust_noforecast = cust_rows.none? { |r| r["summary"] == "forecast" }

own_key  = OpenSSL::PKey::RSA.generate(2048)
own_pem  = own_key.public_key.to_pem
_rc_o, rc_own_poll, own_claim_token, own_page = claim_ceremony(owner_session, own_key, own_pem)
own_claim_role = token_role(own_claim_token)["role"]
rc_own_cal, own_cal = WIRE.get_json("/kiosk/salon_calendar", {}, WIRE.bearer(own_claim_token))
own_rows        = Array(own_cal)
own_sees_others = own_rows.any? { |r| r["id"] == appt_id_b3 }
own_forecast    = own_rows.any? { |r| r["summary"] == "forecast" }

BATTERY.record("DeviceGrantRoleComesFromTheApprover",
               rc_cust_poll == 200 && cust_claim_role == "customer" &&
                 rc_cust_cal == 200 && cust_sees_own && cust_own_only && cust_noforecast &&
                 rc_own_poll == 200 && own_claim_role == "owner" &&
                 rc_own_cal == 200 && own_sees_others && own_forecast,
               "customer-approved claim → poll #{rc_cust_poll}, token role #{cust_claim_role.inspect}, " \
               "calendar #{rc_cust_cal} sees_own=#{cust_sees_own} own_only=#{cust_own_only} " \
               "forecast_hidden=#{cust_noforecast}; " \
               "CONTROL owner-approved claim over the SAME endpoints → poll #{rc_own_poll}, token role " \
               "#{own_claim_role.inspect}, calendar #{rc_own_cal} whole_book=#{own_sees_others} " \
               "forecast=#{own_forecast} (want customer/own-scoped and owner/whole-book — the role is the " \
               "approver's, never the caller's)")

# The verify page names the role it grants, and differs per approver.
cust_page_names  = cust_page.to_s.include?("Access you are handing it") &&
                   cust_page.to_s.include?("<code>customer</code>")
own_page_names   = own_page.to_s.include?("Access you are handing it") &&
                   own_page.to_s.include?("<code>owner</code>")
pages_differ     = !cust_page.to_s.include?("<code>owner</code>")
BATTERY.record("DeviceGrantVerifyPageNamesTheAccess",
               cust_page_names && own_page_names && pages_differ,
               "customer's verify page names `customer`: #{cust_page_names}; owner's names `owner`: " \
               "#{own_page_names}; the customer's page does NOT say owner: #{pages_differ} " \
               "(want all three — the field is the approver's real role, not a constant)")

# Re-running the ceremony with a bound key (rebind) still yields the approver's role.
rc_rebind_refused, rebind_refused_body =
  oauth_post("/kiosk/oauth/device_authorization",
             { "client_id" => "redteam-rebind", "public_key" => cust_pem, "role" => "owner" })
_rc_r, rc_rebind_poll, rebind_token, = claim_ceremony(customer_session, cust_key, cust_pem)
rebind_claims = token_role(rebind_token)
rebind_role   = rebind_claims["role"]
rebind_stable = rebind_claims["agent_id"] == token_role(cust_token)["agent_id"]
rc_rebind_cal, rebind_cal = WIRE.get_json("/kiosk/salon_calendar", {}, WIRE.bearer(rebind_token))
rebind_rows      = Array(rebind_cal)
# Positive control: the rebound token still reads Alice's book.
rebind_sees_own  = rebind_rows.any? { |r| r["id"] == appt_id_a }
rebind_own_only  = rebind_rows.none? { |r| r["id"] == appt_id_b3 }
rebind_noforecast = rebind_rows.none? { |r| r["summary"] == "forecast" }
BATTERY.record("DeviceGrantRebindCannotEscalate",
               rc_rebind_refused == 400 && rebind_refused_body["error"] == "invalid_request" &&
                 rc_rebind_poll == 200 && rebind_role == "customer" && rebind_stable &&
                 rc_rebind_cal == 200 && rebind_sees_own && rebind_own_only && rebind_noforecast,
               "known key re-runs the ceremony: role=owner → #{rc_rebind_refused}/" \
               "#{rebind_refused_body['error'].inspect}; the honest re-run → poll #{rc_rebind_poll}, " \
               "role #{rebind_role.inspect}, agent_id stable=#{rebind_stable}, calendar #{rc_rebind_cal} " \
               "sees_own=#{rebind_sees_own} own_only=#{rebind_own_only} " \
               "forecast_hidden=#{rebind_noforecast} (want the rebind to stay " \
               "the approver's role, not one ceremony later\'s escalation)")

# An unsigned `agent:u-…:r-owner` bearer resolves to no identity; the owner's real token is the control.
forged_owner_bearer = WIRE.bearer("agent:u-#{OWNER_ID}:a-#{SecureRandom.uuid}:r-owner")
rc_forged_cal, = WIRE.get_json("/kiosk/salon_calendar", {}, forged_owner_bearer)
rc_forged_book, = WIRE.post_json("/kiosk/book_appointment",
                                 { salon_id: salon_id, slot: FUTURE_SLOT.call(5) },
                                 forged_owner_bearer)
rc_owner_cal, owner_cal = WIRE.get_json("/kiosk/salon_calendar", {}, WIRE.bearer(owner_token))
owner_sees_forecast = Array(owner_cal).any? { |r| r["summary"] == "forecast" }
BATTERY.record("SelfAssertedTokenForgery",
               rc_forged_cal == 401 && rc_forged_book == 401 &&
                 rc_owner_cal == 200 && owner_sees_forecast,
               "self-asserted `agent:u-#{OWNER_ID}:a-…:r-owner` → salon_calendar #{rc_forged_cal}, " \
               "book_appointment #{rc_forged_book} (want 401/401: it resolves to NO identity, in THIS " \
               "environment — no env gate involved); CONTROL the owner's GENUINELY-BOUND token → " \
               "salon_calendar #{rc_owner_cal}, forecast_visible=#{owner_sees_forecast} (want 200/true, so " \
               "the refusal is about the bearer and not a closed endpoint)")

# A self-asserted X-Staff-Session header buys nothing; the owner's real session is the control.
self_asserted_staff_forgery = lambda do
  rc_forged, = WIRE.post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => OWNER_ID })
  rc_real, _link = owner_session.post_json("/kiosk/auth/link", {}, { session: true })

  blocked = rc_forged == 401 && rc_real == 201
  detail =
    if blocked
      "forged `X-Staff-Session` naming the owner → 401 at /kiosk/auth/link in the SAME env this " \
        "suite drives (nothing anywhere reads the header); the " \
        "owner's REAL Devise session still mints (201), so the refusal is not vacuous"
    elsif rc_forged != 401
      "REGRESSION: forged X-Staff-Session was accepted at /kiosk/auth/link (HTTP #{rc_forged})"
    else
      "unexpected: the owner's REAL Devise session was refused too (HTTP #{rc_real}) — the 401 " \
        "above proves nothing"
    end
  BATTERY.record("SelfAssertedStaffSessionForgery", blocked, detail)
rescue StandardError => e
  BATTERY.record("SelfAssertedStaffSessionForgery", false, "beat error: #{e.class}: #{e.message}")
end
self_asserted_staff_forgery.call

# Bad booking input is a typed 400 without PG internals, never a 500 or a silent booking.
BAD_INPUTS = [
  ["unparseable slot",        { salon_id: :seeded, slot: "banana" }],
  ["fuzzy slot (silent past booking)", { salon_id: :seeded, slot: "next tuesday" }],
  ["empty slot",              { salon_id: :seeded, slot: "" }],
  ["missing slot",            { salon_id: :seeded }],
  ["non-string slot",         { salon_id: :seeded, slot: 12345 }],
  ["out-of-range slot",       { salon_id: :seeded, slot: "2026-13-45T99:00:00Z" }],
  # Well-formed but past; the probes below carry a future slot so only their own field is wrong.
  ["past slot (well-formed, already gone)", { salon_id: :seeded, slot: PAST_SLOT }],
  ["unknown salon_id",        { salon_id: 999_999, slot: FUTURE_SLOT.call(1) }],
  ["missing salon_id",        { slot: FUTURE_SLOT.call(1) }],
  ["unknown service_id",      { salon_id: :seeded, slot: FUTURE_SLOT.call(1), service_id: 999_999 }],
].freeze
PG_INTERNALS = ["PG::", "NotNullViolation", "RecordInvalid", "DatatypeMismatch", "violates not-null"].freeze

bad_failures = []
BAD_INPUTS.each do |label, args|
  body = args.dup
  body[:salon_id] = salon_id if body[:salon_id] == :seeded
  rc, resp = WIRE.post_json("/kiosk/book_appointment", body, ALICE.bearer)
  code = resp.is_a?(Hash) ? resp["code"] : nil
  # `supplied:` keeps the probe's own echoed bytes from reading as a leak.
  scan = Kiosk::Redteam::LeakScan.scan(resp, PG_INTERNALS, supplied: body)
  next if rc == 400 && code == "bad_request" && !scan.leak?

  bad_failures << "#{label} → HTTP #{rc} code=#{code.inspect}" \
                  "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}" \
                  "#{rc == 200 ? " (SILENTLY BOOKED)" : ""}"
end

# Positive controls: a bare and a priced booking still succeed.
rc_bare, bare = WIRE.post_json("/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(3) }, ALICE.bearer)
bad_failures << "CONTROL bare salon booking → HTTP #{rc_bare} #{JSON.generate(bare)[0, 160]}" unless rc_bare == 200

rc_menu, menu = WIRE.get_json("/kiosk/service_menu", {}, ALICE.bearer)
service = Array(menu).find { |r| r["price_cents"].to_i.positive? }
rc_full, full = WIRE.post_json("/kiosk/book_appointment",
       { salon_id: salon_id, slot: FUTURE_SLOT.call(4),
         service_id: service && service["service_id"] }, ALICE.bearer)
unless rc_menu == 200 && rc_full == 200 && full["price_cents"].to_i == service["price_cents"].to_i
  bad_failures << "CONTROL priced booking → HTTP #{rc_full} price_cents=#{full["price_cents"].inspect} " \
                  "(want #{service && service["price_cents"].inspect})"
end

BATTERY.record("UntypedBookingInput", bad_failures.empty?,
               bad_failures.empty? ? "#{BAD_INPUTS.size} bad-input shapes → typed 400 bad_request, no PG internals; bare + priced bookings still succeed" : bad_failures.join(" | "))

# The shared kiosk-redteam beat; this origin declares two roles, so a skip is a breach.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client:  Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer owner]),
  on_skip: :breach,
)

# 0 only when every beat ran and was blocked; stylish expects no skips.
exit BATTERY.report!
