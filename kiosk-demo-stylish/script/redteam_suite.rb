# frozen_string_literal: true

# Adversarial regression battery for stylish (Combette salon booking).
#
# Runs a set of attacks against the live stylish surface (salons /
# my_appointments queries, book_appointment action) and asserts each is
# BLOCKED. This demo has no payment or KYC surface, so the battery covers the
# attacks that actually apply to it — cross-tenant reads, forged principal
# args, and the auth/dispatch boundary — rather than fabricating scenarios the
# surface cannot exhibit.
#
# Scenarios (each must be BLOCKED):
#   CrossTenantRead    — B's my_appointments must NOT contain A's appointment
#   ForgedUserId       — an agent-supplied user_id in book_appointment args is
#     REFUSED (400 bad_request naming it) and B's own booking never lands under A
#   MissingAuth        — a request with no Authorization → 401
#   GarbageToken       — an unparseable bearer token → 401
#   UnknownQuery       — an unregistered query name → 404
#   UnknownAction      — an unregistered action name → 404
#   RetiredWire        — the deleted 0.3 `POST /kiosk/query` and `POST /kiosk/run`
#     answer the ordinary 404 an authenticated caller gets, and 401 without a
#     bearer: no privileged endpoint, no compatibility payload
#   MethodMismatch     — a GET at an action's path → 405 method_not_allowed with
#     `Allow: POST`, never a silent 404
#   CustomerLinkCannotCarryOwnerRole — a CUSTOMER (non-staff) signs in for real
#     and mints an assistant link; the link is legitimate but the role it
#     carries is `customer`, because the role is read off the human's own
#     staff_role — owner scope is unreachable from a customer session
#   OwnerLinkIgnoresForgedClaimBody — a genuine OWNER link smuggles a wider
#     role into the claim body; the bound token role comes from the IdP
#     session, not the body, so the forged role is ignored
#   CustomerCalendarStaysOwnScoped — a customer's agent sees only its OWN
#     bookings (no whole-book, no forecast) in salon_calendar — the role gate
#     is provider-controlled and un-bypassable
#   DeviceGrantCannotSelfSelectRole — the CLAIM ceremony's unauthenticated
#     opening request may not name a role: `role`/`scope`, declared value or
#     not, is 400 invalid_request, while the role-less request still opens
#   DeviceGrantRoleComesFromTheApprover — the same endpoints yield `customer`
#     for a customer-approved ceremony (own bookings, no forecast) and `owner`
#     for an owner-approved one (whole book + forecast): the role is the
#     approver's, both directions asserted so neither constant would pass
#   DeviceGrantVerifyPageNamesTheAccess — the consent page names the role it is
#     handing over, and names a DIFFERENT one to each human
#   DeviceGrantRebindCannotEscalate — a key already bound `customer` re-runs the
#     ceremony: the role stays `customer`, agent_id stable, calendar own-scoped
#   SelfAssertedTokenForgery — the AGENT sibling of the beat below (K-539 /
#     T-104): a self-asserted `agent:u-…:a-…:r-owner` bearer naming the seeded
#     owner resolves to NO identity, in EVERY environment, while the OWNER's
#     genuinely-bound token reaches the whole book and the forecast
#   SelfAssertedStaffSessionForgery — a forged `X-Staff-Session` header naming
#     the seeded owner buys NOTHING over the live wire (K-555 / T-066): the
#     role-carrying SSO stand-in that read that header is deleted, so the
#     header reaches no reader and /kiosk/auth/link answers 401 in the SAME
#     environment this suite drives — no in-process env shim needed any more
#
#   UntypedBookingInput — ten bad-input shapes to book_appointment (unparseable
#     / fuzzy / missing / non-string / PAST slot, unknown & missing salon_id,
#     unknown service_id) are each a typed 400 with no PG internals — never a
#     500 and never a silent booking — while a bare and a priced booking still
#     succeed
#
#   DeviceGrantRoleSelfSelection (from `kiosk-redteam`, shared by every demo) —
#     the account-binding claim ceremony's UNAUTHENTICATED opening request
#     refuses `role`/`scope` at a DECLARED value as well as an invented one,
#     while the role-less request still opens the ceremony (K-072, K-1128)
#
# THE TWO CUSTOMER PRINCIPALS ARE EARNED, NOT ASSERTED (T-104). Alice and Bob
# are bound through the shipped ceremony — Equihash-tolled `/auth/register` →
# the human's real Devise sign-in → `/auth/link` → `/auth/claim`
# (script/bound_assistant.rb) — because the dev-only parser that used to turn a
# written-down `agent:u-…:a-…:r-…` string into an identity at any role is
# deleted. That is also what promotes the SelfAssertedTokenForgery beat below
# from an in-process probe under a stubbed production config into an ordinary
# over-the-wire attack in the SAME environment this suite drives.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   ALICE_EMAIL=alice@example.com BOB_EMAIL=bob@example.com \
#   OWNER_EMAIL=owner@combette.example DEMO_PASSWORD=… \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED; exits 1 on any BREACH.
# A BREACH = a real hole in stylish — fix the app, not the scenario.

require "date"
require "json"
require "net/http"
require "time"
require "uri"
require "jwt"
require "openssl"
require "securerandom"
require "base64"

# The shared harness. Required HERE rather than beside the one framework beat
# further down, because {Kiosk::Redteam::LeakScan} — the oracle every leak
# assertion in this file now asks — is needed from the first hostile-input beat
# onwards (T-121).
require "kiosk/redteam"

require_relative "bound_assistant"
require_relative "devise_session"

# ── Every slot this suite books is COMPUTED, never written down (K-969) ──────
#
# Since a slot in the past is refused, a literal instant is a test that expires:
# the seven positive controls below all named days in October 2026 and would
# have started failing on the first of them, for a reason having nothing to do
# with the behaviour under test — the same trap the descriptor's `example_params`
# was rewritten to avoid. `n` separates the bookings from each other (this salon
# overbooks by design, so they need not be distinct — they are distinct only so
# a failure names which control it was).
#
# UTC and not the runner's zone, deliberately: an ISO 8601 instant WITH an
# offset is absolute, so the assertion holds from any caller's clock — which is
# the whole reason stylish's floor is an instant rather than a day.
FUTURE_SLOT = lambda { |n, hour = 9|
  d = Date.today + 30 + n
  Time.utc(d.year, d.month, d.day, hour, 0, 0).iso8601
}
PAST_SLOT = "1900-01-01T09:00:00Z"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# The seeded humans this battery drives (db/seeds.rb). Only the owner carries a
# `staff_role`; Alice and Bob are plain customers. All three are ordinary Devise
# accounts — the same /users/sign_in form, the same users table; what separates
# them is the column the Devise adapter reads through `User#kiosk_role` (T-066:
# there is no second, role-carrying channel any more).
#
# Emails and password arrive in the environment from the rake task, the way
# demo:binding's HOLDER_EMAIL / HOLDER_PASSWORD do — never as literals here.
OWNER_ID      = "00000000-0000-0000-0000-0000000000a0"
OWNER_EMAIL   = ENV.fetch("OWNER_EMAIL")
ALICE_EMAIL   = ENV.fetch("ALICE_EMAIL")
BOB_EMAIL     = ENV.fetch("BOB_EMAIL")
DEMO_PASSWORD = ENV.fetch("DEMO_PASSWORD")

# The owner's browser session, signed in once and reused by the beats below.
def owner_session
  @owner_session ||= DeviseSession.new(SERVER)
                                  .sign_in!(email: OWNER_EMAIL, password: DEMO_PASSWORD)
end

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` carrying its
# arguments as the JSON body; a query is `GET <endpoint>/<query-name>` carrying
# them in the query string. A success body IS the result; an error is an RFC
# 9457 problem document whose branch point is the TOP-LEVEL `code`.
def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, headers = {}, params = {})
  uri = URI("#{SERVER}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token)
  { "Authorization" => "Bearer #{token}" }
end

def pop_proof(key, pem)
  _rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

# Mint a link over a REAL owner Devise session, optionally trying to smuggle a
# wider role in the claim body. Returns [http, claimed_body]. Used to prove the
# owner scope is only reachable through a genuine owner session, and that the
# claim body cannot widen it.
def link_as_owner(extra_claim_body = {})
  rc, link = owner_session.post_json("/kiosk/auth/link", {}, { session: true })
  return [rc, link] unless rc == 201

  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem
  post_json("/kiosk/auth/claim",
            { code: link.fetch("link_code"), public_key: pem, signed: pop_proof(key, pem) }.merge(extra_claim_body))
end

results  = []
def record(results, name, blocked, detail)
  results << { name: name, blocked: blocked, detail: detail }
  tag = blocked ? "BLOCKED" : "BREACH "
  puts "  #{tag}  #{name} — #{detail}"
end

# ── Fixture: two customer principals, EARNED through the shipped ceremony ─────
ALICE = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: DEMO_PASSWORD)
BOB   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: DEMO_PASSWORD)
abort "both assistants bound to the SAME account (#{ALICE.user_id}) — no boundary to attack" \
  if ALICE.user_id == BOB.user_id

# ── Fixture: A books an appointment (target for cross-tenant probes) ──────────
rc, salons = get_json("/kiosk/salons", ALICE.bearer)
abort "salons query failed (#{rc}): #{JSON.generate(salons)} — run rake demo:setup" unless rc == 200
salon_id = Array(salons).first&.fetch("salon_id")
abort "no salons seeded — run rake demo:setup" unless salon_id

rc, appt_a = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(1) },
  ALICE.bearer,
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a)}" unless rc == 200
appt_id_a = appt_a["appointment_id"]

# ── CrossTenantRead — B must not see A's appointment ─────────────────────────
rc, b_appts = get_json("/kiosk/my_appointments", BOB.bearer)
b_ids = Array(b_appts).map { |r| r["id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(appt_id_a),
       "B's my_appointments #{b_ids.inspect} excludes A's #{appt_id_a}")

# ── ForgedUserId — B books with A's user_id in the args ──────────────────────
#
# THIS BEAT CHANGED SHAPE AT 0.4 AND GOT STRONGER, so it is worth saying what it
# now proves. Through 0.3 the forged argument was ACCEPTED by the wire and
# IGNORED by the handler, and the proof was indirect: the created appointment
# did not surface in A's my_appointments. On the 0.4 wire `input_schema` is
# validated on every call and `book_appointment` declares
# `additionalProperties: false` — the principal is not one of its inputs — so
# the forgery is REFUSED before the handler runs, with a typed 400 naming the
# offending parameter. Both halves are asserted: the wire refuses it, AND
# nothing belonging to B appears under A.
rc, forged = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(2), user_id: ALICE.user_id },
  BOB.bearer,
)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("user_id")

# And the principal really does come from the token, not from anything the
# caller sent: B's LEGITIMATE booking lands under B and never under A.
rc_b, bobs = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(2, 10) },
  BOB.bearer,
)
appt_id_bob = bobs["appointment_id"]
rc_a, a_appts = get_json("/kiosk/my_appointments", ALICE.bearer)
a_ids = Array(a_appts).map { |r| r["id"] }
record(results, "ForgedUserId",
       refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(appt_id_bob),
       "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
       "A's list #{a_ids.inspect} excludes B's #{appt_id_bob.inspect}")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = get_json("/kiosk/salons")
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = get_json("/kiosk/salons", bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = get_json("/kiosk/frobnicate", ALICE.bearer)
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/nope", {}, ALICE.bearer)
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 an AUTHENTICATED caller gets — no privileged
# endpoint, no compatibility payload, no second conformance surface to attack.
#
# BOTH CALLERS ARE PROBED, and that is the whole point of the qualifier above
# (K-1094). `VerbController#serve` resolves the identity BEFORE it looks the
# verb up, so a caller with no bearer never reaches the registry lookup that
# produces the 404 — it is answered 401 `unauthenticated`, exactly as it would
# be at any other name. Every retired-wire beat in the fleet dialled WITH a
# bearer, so seven suites' prose said the 404 flatly while nothing anywhere
# tested the anonymous case the sentence was wrong about.
#
# The 404's code is `verb_not_found` since T-158, not `not_found`: `query` and
# `run` are NAMES nobody registered, and the vocabulary now reserves
# `not_found` for an argument that ADDRESSED something absent.
retired = %w[query run].map do |name|
  rc_r, body_r = post_json("/kiosk/#{name}", { name: "salons" }, ALICE.bearer)
  [rc_r == 404 && body_r["code"] == "verb_not_found", "#{name}→#{rc_r}/#{body_r['code'].inspect}"]
end
retired_anon = %w[query run].map do |name|
  rc_a, body_a = post_json("/kiosk/#{name}", { name: "salons" })
  [rc_a == 401 && body_a["code"] == "unauthenticated", "#{name}(anon)→#{rc_a}/#{body_a['code'].inspect}"]
end
record(results, "RetiredWire", (retired + retired_anon).all? { |ok, _| ok },
       "0.3 endpoints #{(retired + retired_anon).map(&:last).join(', ')} " \
       "(want 404/\"verb_not_found\" with a bearer, 401/\"unauthenticated\" without)")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
uri405 = URI("#{SERVER}/kiosk/book_appointment")
res405 = Net::HTTP.new(uri405.host, uri405.port)
                  .request(Net::HTTP::Get.new(uri405, ALICE.bearer))
body405 = (JSON.parse(res405.body) rescue {})
record(results, "MethodMismatch",
       res405.code.to_i == 405 && body405["code"] == "method_not_allowed" &&
         res405["allow"].to_s.upcase.include?("POST"),
       "GET an action → #{res405.code}/#{body405['code'].inspect} Allow=#{res405['allow'].inspect} " \
       "(want 405/\"method_not_allowed\"/POST)")

# ── roles-from-IdP escalation beats (Path A) ──────────────────────────
# A customer's agent must NOT be able to obtain owner-scope. Owner scope is
# reachable only through a genuine owner IdP session (never a customer's), and
# even an owner-linking agent that smuggles a wider role into the claim body
# cannot widen it — the role rides the IdP, and salon_calendar's WHERE is
# provider-controlled.

# CustomerLinkCannotCarryOwnerRole — a CUSTOMER (Alice) signs in for real and
# mints an assistant link. The mint SUCCEEDS: she is a legitimate account holder
# and linking her own assistant is the product. What she cannot do is carry the
# owner role into it — the Devise adapter reads `User#kiosk_role`, which returns
# her (absent) staff_role as "customer", so the assistant she binds inherits
# `customer` and owner scope stays out of reach.
#
# THE BEAT CHANGED SHAPE WITH T-066, and the change is the point: it used to
# assert the mint was REJECTED, because the staff channel was a separate
# `X-Staff-Session` stand-in that resolved only staff rows. With one channel for
# every human, "a customer gets no link" would be wrong — the honest claim is
# "a customer gets a CUSTOMER link", which is a stronger statement about where
# the role comes from.
customer_session = DeviseSession.new(SERVER)
                                .sign_in!(email: ALICE_EMAIL, password: DEMO_PASSWORD)
rc_cl, link_cl = customer_session.post_json("/kiosk/auth/link", {}, { session: true })
cust_role = nil
if rc_cl == 201
  ck = OpenSSL::PKey::RSA.generate(2048)
  cpem = ck.public_key.to_pem
  _rc, cclaimed = post_json("/kiosk/auth/claim",
                            { code: link_cl.fetch("link_code"), public_key: cpem,
                              signed: pop_proof(ck, cpem) })
  cseg = cclaimed["access_token"].to_s.split(".")[1].to_s
  cust_role = (JSON.parse(Base64.urlsafe_decode64(cseg + "=" * ((4 - cseg.length % 4) % 4)))["role"] rescue nil)
end
record(results, "CustomerLinkCannotCarryOwnerRole",
       rc_cl == 201 && cust_role == "customer",
       "customer link mint → #{rc_cl}, bound token role #{cust_role.inspect} " \
       "(want 201 + \"customer\"; the role is read off the human, never chosen)")

# OwnerLinkIgnoresForgedClaimBody — link a genuine OWNER while smuggling a wider
# role into the claim body. The bound token must carry `owner` from the IdP, not
# because the body asked — the claim body role is ignored; the IdP session wins.
rc, claimed = link_as_owner(role: "superuser", allowed_roles: ["superuser"], requested_role: "superuser")
owner_token = claimed["access_token"].to_s
seg = owner_token.split(".")[1].to_s
role_claim = (JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))["role"] rescue nil)
record(results, "OwnerLinkIgnoresForgedClaimBody",
       rc == 201 && role_claim == "owner",
       "owner link with forged claim body → token role #{role_claim.inspect} (want \"owner\", body ignored)")

# CustomerCalendarStaysOwnScoped — a plain customer (Alice) calls salon_calendar
# with her own customer-role token; she must see ONLY her own bookings and NO
# forecast total (owner-only). The role gate is provider-controlled.
#
# K-689: `kind == "booking"` proves nothing — config/initializers/kiosk.rb
# stamps `"kind" => "booking"` on EVERY appointment row unconditionally
# (owner-scoped or not), so a leaked owner-scope row is indistinguishable from
# an own row by that test. Book a SECOND customer's (Bob's) appointment here,
# then assert Alice's calendar EXCLUDES that specific booking id — the only
# thing that actually demonstrates scoping.
rc_b3, appt_b3 = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(3) },
  BOB.bearer,
)
appt_id_b3 = appt_b3["appointment_id"]

rc, cal = get_json("/kiosk/salon_calendar", ALICE.bearer)
rows = Array(cal)
own_ids     = rows.reject { |r| r["summary"] }.map { |r| r["id"] }
own_only    = !own_ids.include?(appt_id_b3)
no_forecast = rows.none? { |r| r["summary"] == "forecast" }
record(results, "CustomerCalendarStaysOwnScoped",
       rc == 200 && rc_b3 == 200 && own_only && no_forecast,
       "customer salon_calendar: #{rows.size} rows #{own_ids.inspect}, excludes B's #{appt_id_b3.inspect} " \
       "(own_only=#{own_only}), forecast_hidden=#{no_forecast}")

# ── the CLAIM ceremony's roles-from-IdP beats (K-072) ────────────────────────
#
# The two beats above cover the LINK direction, and covering only that
# direction is what let the hole below live at head. The claim direction —
# RFC 8628, `POST /kiosk/oauth/device_authorization` → the human approves at
# the verify page → the token poll — used to read `role`/`scope` off THAT
# FIRST REQUEST, which carries no Cookie and no Authorization, validate it
# against `config.roles` alone, and bake it into the minted JWT. On this demo
# (`c.roles = %i[customer owner]`) a stranger's `role=owner`, approved by a
# plain CUSTOMER who was never shown the word, reached a token whose `role`
# claim was `owner` and a `salon_calendar` answering with every visitor's
# bookings plus the owner-only forecast. `role=master` was refused, which is
# why a suite that probed only an undeclared role would have kept printing
# BLOCKED: membership of `config.roles` was the entire filter, and
# `config.roles` says which roles this origin HAS, not who may have them.
#
# The role now comes from the approving human's own identity, captured at the
# verify page (`DeviceVerification.approve(role:)`) exactly as the link
# direction captures it at mint — so the three beats below are the claim-side
# mirror of `CustomerLinkCannotCarryOwnerRole` /
# `OwnerLinkIgnoresForgedClaimBody`, plus the rebind case, which is the one a
# first-bind-only fix would leave open.

DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

# The OAuth half of the ceremony is form-encoded (the spec's one deliberate
# exception to the Kiosk problem document), so it needs its own poster.
def oauth_post(path, form)
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri)
  req.set_form_data(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Open a claim ceremony, have `session`'s human approve it on the REAL verify
# page, and poll once with a possession proof. Returns
# [authorization_http, poll_http, token_or_nil, verify_page_html].
#
# It polls ONLY after the approval, so no `sleep` is needed: `slow_down` fires
# on a SECOND poll of the same device_code inside the advertised interval, and
# there is no first one here. (`script/binding_flow.rb` sleeps because it
# deliberately polls once while pending, to show `authorization_pending`.)
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

# ── DeviceGrantCannotSelfSelectRole ──────────────────────────────────────────
# The unauthenticated request that OPENS the ceremony may not name a role, at
# any value or spelling. The DECLARED values are the ones that matter: an
# undeclared `master` was refused before this fix too, so a probe using only
# that would be vacuous.
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

# CONTROL: the SAME request without the parameter opens the ceremony. Without
# it, an origin that refused every device_authorization would print BLOCKED.
control_key = OpenSSL::PKey::RSA.generate(2048)
rc_ctrl, da_ctrl = oauth_post("/kiosk/oauth/device_authorization",
                              { "client_id" => "redteam-selfselect",
                                "public_key" => control_key.public_key.to_pem })
control_ok = rc_ctrl == 200 && da_ctrl["user_code"].to_s.match?(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
record(results, "DeviceGrantCannotSelfSelectRole",
       self_selection.all? { |ok, _| ok } && control_ok,
       "#{self_selection.map(&:last).join('; ')}; CONTROL role-less request → #{rc_ctrl} " \
       "user_code=#{da_ctrl['user_code'].inspect} (want every role/scope 400/invalid_request, " \
       "and the role-less ceremony still opening)")

# ── DeviceGrantRoleComesFromTheApprover ──────────────────────────────────────
# Both halves in one beat, because either alone is misreadable: a customer's
# ceremony must land at `customer` (own bookings, no forecast) AND an owner's
# ceremony over the SAME endpoints must land at `owner` (whole book +
# forecast). Without the second, "always customer" would pass; without the
# first, "always owner" would.
cust_key  = OpenSSL::PKey::RSA.generate(2048)
cust_pem  = cust_key.public_key.to_pem
_rc_a, rc_cust_poll, cust_token, cust_page = claim_ceremony(customer_session, cust_key, cust_pem)
cust_claim_role = token_role(cust_token)["role"]
rc_cust_cal, cust_cal = get_json("/kiosk/salon_calendar", bearer(cust_token))
cust_rows      = Array(cust_cal)
cust_own_only  = cust_rows.none? { |r| r["id"] == appt_id_b3 }
cust_noforecast = cust_rows.none? { |r| r["summary"] == "forecast" }

own_key  = OpenSSL::PKey::RSA.generate(2048)
own_pem  = own_key.public_key.to_pem
_rc_o, rc_own_poll, own_claim_token, own_page = claim_ceremony(owner_session, own_key, own_pem)
own_claim_role = token_role(own_claim_token)["role"]
rc_own_cal, own_cal = get_json("/kiosk/salon_calendar", bearer(own_claim_token))
own_rows        = Array(own_cal)
own_sees_others = own_rows.any? { |r| r["id"] == appt_id_b3 }
own_forecast    = own_rows.any? { |r| r["summary"] == "forecast" }

record(results, "DeviceGrantRoleComesFromTheApprover",
       rc_cust_poll == 200 && cust_claim_role == "customer" &&
         rc_cust_cal == 200 && cust_own_only && cust_noforecast &&
         rc_own_poll == 200 && own_claim_role == "owner" &&
         rc_own_cal == 200 && own_sees_others && own_forecast,
       "customer-approved claim → poll #{rc_cust_poll}, token role #{cust_claim_role.inspect}, " \
       "calendar #{rc_cust_cal} own_only=#{cust_own_only} forecast_hidden=#{cust_noforecast}; " \
       "CONTROL owner-approved claim over the SAME endpoints → poll #{rc_own_poll}, token role " \
       "#{own_claim_role.inspect}, calendar #{rc_own_cal} whole_book=#{own_sees_others} " \
       "forecast=#{own_forecast} (want customer/own-scoped and owner/whole-book — the role is the " \
       "approver's, never the caller's)")

# ── DeviceGrantVerifyPageNamesTheAccess ──────────────────────────────────────
# The consent half. An approval given without seeing what it grants is not
# consent to anything in particular, and this page used to show a fingerprint
# and a timestamp only — measured, while a `role=owner` ceremony was pending on
# it. Asserted on BOTH humans' pages and required to DIFFER, so a constant
# string cannot satisfy it.
cust_page_names  = cust_page.to_s.include?("Access you are handing it") &&
                   cust_page.to_s.include?("<code>customer</code>")
own_page_names   = own_page.to_s.include?("Access you are handing it") &&
                   own_page.to_s.include?("<code>owner</code>")
pages_differ     = !cust_page.to_s.include?("<code>owner</code>")
record(results, "DeviceGrantVerifyPageNamesTheAccess",
       cust_page_names && own_page_names && pages_differ,
       "customer's verify page names `customer`: #{cust_page_names}; owner's names `owner`: " \
       "#{own_page_names}; the customer's page does NOT say owner: #{pages_differ} " \
       "(want all three — the field is the approver's real role, not a constant)")

# ── DeviceGrantRebindCannotEscalate ──────────────────────────────────────────
# A fix that only guarded FIRST binding would leave the same escalation one
# ceremony later: a known key re-running the claim ceremony takes the rebind
# branch, whose `allowed_roles` REMAP is what the self-selected role used to
# drive (measured at head: a key bound `customer` came back `owner`, same
# agent_id). So the same key that is now bound at `customer` runs it again.
rc_rebind_refused, rebind_refused_body =
  oauth_post("/kiosk/oauth/device_authorization",
             { "client_id" => "redteam-rebind", "public_key" => cust_pem, "role" => "owner" })
_rc_r, rc_rebind_poll, rebind_token, = claim_ceremony(customer_session, cust_key, cust_pem)
rebind_claims = token_role(rebind_token)
rebind_role   = rebind_claims["role"]
rebind_stable = rebind_claims["agent_id"] == token_role(cust_token)["agent_id"]
rc_rebind_cal, rebind_cal = get_json("/kiosk/salon_calendar", bearer(rebind_token))
rebind_rows      = Array(rebind_cal)
rebind_own_only  = rebind_rows.none? { |r| r["id"] == appt_id_b3 }
rebind_noforecast = rebind_rows.none? { |r| r["summary"] == "forecast" }
record(results, "DeviceGrantRebindCannotEscalate",
       rc_rebind_refused == 400 && rebind_refused_body["error"] == "invalid_request" &&
         rc_rebind_poll == 200 && rebind_role == "customer" && rebind_stable &&
         rc_rebind_cal == 200 && rebind_own_only && rebind_noforecast,
       "known key re-runs the ceremony: role=owner → #{rc_rebind_refused}/" \
       "#{rebind_refused_body['error'].inspect}; the honest re-run → poll #{rc_rebind_poll}, " \
       "role #{rebind_role.inspect}, agent_id stable=#{rebind_stable}, calendar #{rc_rebind_cal} " \
       "own_only=#{rebind_own_only} forecast_hidden=#{rebind_noforecast} (want the rebind to stay " \
       "the approver's role, not one ceremony later\'s escalation)")

# ── SelfAssertedTokenForgery (K-539 / T-104) — OVER THE LIVE WIRE ─────────────
#
# THE BEAT CHANGED SHAPE, AND THE CHANGE IS THE POINT. stylish used to compose a
# hand-copied agent-IdP that parsed a self-asserted, UNSIGNED
# `agent:u-<user>:a-<agent>:r-<role>` bearer straight into an authenticated
# identity — at whatever role the string named, including `owner`. It was live
# in development on purpose (every driver in this repo, including this suite,
# held itself a principal that way), so the block could only ever be
# demonstrated IN-PROCESS against a stubbed production Rails.env, and an env
# gate was the whole defence.
#
# There is no such parser any more, in any environment: `c.agent_idp` is unset,
# so the engine's own DefaultAgentIdp verifies the kiosk-pop JWTs it minted and
# nothing else. So this is now an ordinary over-the-wire probe in the SAME
# environment this suite drives, which is a strictly stronger claim than the one
# an env gate could support.
#
# The forged string is deliberately maximal: it names the seeded SALON OWNER's
# real account and `r-owner` — a role stylish genuinely configures and genuinely
# gates on, so this is the exact escalation the parser used to grant. It is
# aimed at `salon_calendar`, the verb that escalation was worth having.
#
# TWO positive controls, because a refusal on its own proves nothing here:
#   • the OWNER's genuinely-bound token reaches the very scope the forgery
#     wanted — the whole book, with the forecast row — so the 401 is about the
#     bearer and not about the endpoint being shut;
#   • it is reached through the real ceremony, which is the only door left.
forged_owner_bearer = bearer("agent:u-#{OWNER_ID}:a-#{SecureRandom.uuid}:r-owner")
rc_forged_cal, = get_json("/kiosk/salon_calendar", forged_owner_bearer)
rc_forged_book, = post_json("/kiosk/book_appointment",
                            { salon_id: salon_id, slot: FUTURE_SLOT.call(5) },
                            forged_owner_bearer)
rc_owner_cal, owner_cal = get_json("/kiosk/salon_calendar", bearer(owner_token))
owner_sees_forecast = Array(owner_cal).any? { |r| r["summary"] == "forecast" }
record(results, "SelfAssertedTokenForgery",
       rc_forged_cal == 401 && rc_forged_book == 401 &&
         rc_owner_cal == 200 && owner_sees_forecast,
       "self-asserted `agent:u-#{OWNER_ID}:a-…:r-owner` → salon_calendar #{rc_forged_cal}, " \
       "book_appointment #{rc_forged_book} (want 401/401: it resolves to NO identity, in THIS " \
       "environment — no env gate involved); CONTROL the owner's GENUINELY-BOUND token → " \
       "salon_calendar #{rc_owner_cal}, forecast_visible=#{owner_sees_forecast} (want 200/true, so " \
       "the refusal is about the bearer and not a closed endpoint)")

# ── SelfAssertedStaffSessionForgery (K-555 / T-066) — OVER THE LIVE WIRE ──────
# The HUMAN sibling of the K-539 agent-stub forgery, and it changed shape when
# the stub it attacked was deleted.
#
# stylish used to map a self-asserted `X-Staff-Session: <user_id>` header to a
# role-carrying HUMAN identity — the salon's SSO/Okta stand-in — so on the wire
# that header SELF-GRANTED a staff role. It was live in development on purpose
# (demo:roles walked it), which is why the block could only be shown IN-PROCESS
# against a stubbed production Rails.env.
#
# There is no such arm any more, in any environment: `c.user_idp` is the Devise
# adapter alone, and nothing reads that header. So the beat is now what it
# should always have been — an over-the-wire probe in the SAME environment this
# suite drives. A forged `X-Staff-Session` naming the seeded owner must buy
# NOTHING (401 at /kiosk/auth/link), and the positive control is the real thing:
# the owner's own Devise session mints a link on that very endpoint.
self_asserted_staff_forgery = lambda do
  rc_forged, = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => OWNER_ID })
  rc_real, _link = owner_session.post_json("/kiosk/auth/link", {}, { session: true })

  blocked = rc_forged == 401 && rc_real == 201
  detail =
    if blocked
      "forged `X-Staff-Session` naming the owner → 401 at /kiosk/auth/link in the SAME env this " \
        "suite drives (the role-carrying stand-in is deleted; nothing reads the header); the " \
        "owner's REAL Devise session still mints (201), so the refusal is not vacuous"
    elsif rc_forged != 401
      "K-555 REGRESSION: forged X-Staff-Session was accepted at /kiosk/auth/link (HTTP #{rc_forged})"
    else
      "unexpected: the owner's REAL Devise session was refused too (HTTP #{rc_real}) — the 401 " \
        "above proves nothing"
    end
  record(results, "SelfAssertedStaffSessionForgery", blocked, detail)
rescue StandardError => e
  record(results, "SelfAssertedStaffSessionForgery", false, "beat error: #{e.class}: #{e.message}")
end
self_asserted_staff_forgery.call

# ── UntypedBookingInput (K-692) — bad input is a typed 400, never a 500 and ──
# never a silent booking.
#
# `book_appointment` used to validate NOTHING, and the three ways that failed
# were not equally visible. An unparseable `slot` and an unknown `salon_id`
# blew up as opaque 500s with PG internals in the message; an unknown
# `service_id` was the worst of the three, because it SUCCEEDED — HTTP 200,
# an appointment with no service and `price_cents` NULL, which the owner's
# revenue forecast then summed as €0 while the calendar rendered it as an
# ordinary booking. Nothing anywhere surfaced it, which is exactly why it
# survived: a silent wrong answer has no failing test to write itself.
#
# The catalogue of shapes is deliberately wider than the three named cases,
# because ActiveRecord's timestamp cast fails in two directions: "banana"
# casts to nil (→ NOT NULL violation), while "next tuesday" cast to TODAY AT
# MIDNIGHT and booked a real appointment in the past.
#
# Each probe asserts HTTP 400 AND the problem document's TOP-LEVEL
# `code == "bad_request"` AND no PG internals in the body — a "not 200"
# assertion would accept the 500s this beat exists to forbid.
#
# Since 0.4 some of these shapes are refused one layer earlier: `input_schema`
# is validated on every call, so a non-string or missing `slot` and a missing
# `salon_id` are caught by the declaration before the handler's guards run.
# The verdict an assistant sees is the same typed 400 either way, which is why
# the assertion is written against the STATUS and CODE rather than against a
# sentence one particular layer happened to phrase.
BAD_INPUTS = [
  ["unparseable slot",        { salon_id: :seeded, slot: "banana" }],
  ["fuzzy slot (silent past booking)", { salon_id: :seeded, slot: "next tuesday" }],
  ["empty slot",              { salon_id: :seeded, slot: "" }],
  ["missing slot",            { salon_id: :seeded }],
  ["non-string slot",         { salon_id: :seeded, slot: 12345 }],
  ["out-of-range slot",       { salon_id: :seeded, slot: "2026-13-45T99:00:00Z" }],
  # K-969. A well-formed instant that has PASSED. It parses (so the guard above
  # never sees it), it is not fuzzy, and until today it booked a real
  # appointment a century ago that the owner's calendar rendered as an ordinary
  # row. The other three below carry a FUTURE slot on purpose: each is probing
  # something OTHER than the time, and a stale literal would have started
  # refusing them for the wrong reason once this guard existed.
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
  rc, resp = post_json("/kiosk/book_appointment", body, ALICE.bearer)
  code = resp.is_a?(Hash) ? resp["code"] : nil
  # THE SCAN IS TOLD WHAT THIS PROBE SENT (T-121). `salon_id` is a bare
  # `{type: "integer"}` and `slot` a bare `{type: "string"}` — the bookable
  # instants are a rolling calendar no JSON Schema can name — so hostile values
  # reach stylish's own guards, whose refusals name what they got. The bytes
  # searched for PG_INTERNALS are therefore partly the probe's own, and without
  # `supplied:` a slot spelling `PG::` would be reported as a BREACH on its own
  # echo, under a runner whose prose says a BREACH means "fix the app, not the
  # scenario". {Kiosk::Redteam::LeakScan} discounts a needle only where those
  # exact bytes lie inside one contiguous run the probe supplied — not a blind
  # `gsub`, which could erase a real leak instead.
  scan = Kiosk::Redteam::LeakScan.scan(resp, PG_INTERNALS, supplied: body)
  next if rc == 400 && code == "bad_request" && !scan.leak?

  bad_failures << "#{label} → HTTP #{rc} code=#{code.inspect}" \
                  "#{scan.leak ? " LEAKS #{scan.leak.inspect}" : ""}#{scan.note}" \
                  "#{rc == 200 ? " (SILENTLY BOOKED)" : ""}"
end

# POSITIVE CONTROLS — without them the block above would pass against a handler
# that simply refused every booking. A bare salon booking (no service_id at all)
# is legitimate and the descriptor promises it; a full booking must still
# capture the service price the forecast is summed from.
rc_bare, bare = post_json("/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(3) }, ALICE.bearer)
bad_failures << "CONTROL bare salon booking → HTTP #{rc_bare} #{JSON.generate(bare)[0, 160]}" unless rc_bare == 200

rc_menu, menu = get_json("/kiosk/service_menu", ALICE.bearer)
service = Array(menu).find { |r| r["price_cents"].to_i.positive? }
rc_full, full = post_json("/kiosk/book_appointment",
  { salon_id: salon_id, slot: FUTURE_SLOT.call(4),
    service_id: service && service["service_id"] }, ALICE.bearer)
unless rc_menu == 200 && rc_full == 200 && full["price_cents"].to_i == service["price_cents"].to_i
  bad_failures << "CONTROL priced booking → HTTP #{rc_full} price_cents=#{full["price_cents"].inspect} " \
                  "(want #{service && service["price_cents"].inspect})"
end

record(results, "UntypedBookingInput", bad_failures.empty?,
       bad_failures.empty? ? "#{BAD_INPUTS.size} bad-input shapes → typed 400 bad_request, no PG internals; bare + priced bookings still succeed" : bad_failures.join(" | "))

# ── DeviceGrantRoleSelfSelection — the SHARED framework beat (K-1128) ────────
#
# The one beat in this file that is NOT hand-rolled: it comes from
# `kiosk-redteam`, so every demo runs the SAME assertion about the
# account-binding claim ceremony and a demo cannot be left out of it by
# forgetting to copy a block.
#
# It exists because the coverage that was supposed to catch K-072 rested on a
# condition nobody re-measured: the shared `PrivilegeSelfSelection` scenario
# probes `/auth/register` only, and the ceremony beats written when K-072 was
# fixed lived in ONE demo's suite. The other six were safe purely because each
# declares a single role — which is exactly the mitigation the ledger row had
# priced K-072 on, and which expired unnoticed the day a demo declared a
# second one.
#
# `declared_roles` names what `config/initializers/kiosk.rb` declares here. The
# scenario ALSO derives a declared role from the wire (the `role` claim of a
# token this origin mints at registration), so a stale list weakens the probe
# rather than emptying it — an invented role was refused by the vulnerable code
# too, which is why a probe that names only one cannot fail.
device_grant_beat    = Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new
device_grant_verdict = device_grant_beat.call(
  Kiosk::Redteam::Client.new(base_url: SERVER),
  Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer owner]),
)
# A SKIP is recorded as a breach here on purpose: this origin declares a role,
# so "could not test" is a failure of the harness rather than a property of the
# provider, and a silent third state is what let the last one hide.
record(results, device_grant_beat.name, device_grant_verdict.blocked,
       device_grant_verdict.skipped ? "SKIPPED, which this origin must never do — " \
                                      "#{device_grant_verdict.detail}"
                                    : device_grant_verdict.detail)

# ── Verdict ──────────────────────────────────────────────────────────────────
breaches = results.reject { |r| r[:blocked] }
puts JSON.generate(scenarios: results.size, blocked: results.count { |r| r[:blocked] }, breaches: breaches.map { |r| r[:name] })

if breaches.empty?
  puts "\n  redteam: all #{results.size} scenarios BLOCKED."
  exit 0
else
  puts "\n  redteam: #{breaches.size} BREACH(es): #{breaches.map { |r| r[:name] }.join(', ')}"
  exit 1
end
