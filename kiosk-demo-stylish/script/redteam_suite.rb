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
#     answer an ordinary 404: no privileged endpoint, no compatibility payload
#   MethodMismatch     — a GET at an action's path → 405 method_not_allowed with
#     `Allow: POST`, never a silent 404
#   CustomerCannotMintStaffLink — a CUSTOMER (non-staff) session cannot mint an
#     assistant link over the staff channel; StubUserIdp resolves only staff,
#     so the mint is rejected outright — owner scope is unreachable from one
#   OwnerLinkIgnoresForgedClaimBody — a genuine OWNER link smuggles a wider
#     role into the claim body; the bound token role comes from the IdP
#     session, not the body, so the forged role is ignored
#   CustomerCalendarStaysOwnScoped — a customer's agent sees only its OWN
#     bookings (no whole-book, no forecast) in salon_calendar — the role gate
#     is provider-controlled and un-bypassable
#   SelfAssertedStaffSessionForgery — a forged `X-Staff-Session` header naming
#     the seeded owner resolves to NO identity under a PRODUCTION-config
#     StubUserIdp (K-555), even though the DEV stub this suite runs against
#     intentionally self-grants it — proven in-process against a stubbed
#     Rails.env, since the dev wire this suite drives cannot demonstrate the
#     block
#
#   UntypedBookingInput — nine bad-input shapes to book_appointment (unparseable
#     / fuzzy / missing / non-string slot, unknown & missing salon_id, unknown
#     service_id) are each a typed 400 with no PG internals — never a 500 and
#     never a silent booking — while a bare and a priced booking still succeed
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby script/redteam_suite.rb
#
# Exits 0 when every scenario is BLOCKED; exits 1 on any BREACH.
# A BREACH = a real hole in stylish — fix the app, not the scenario.

require "json"
require "net/http"
require "uri"
require "jwt"
require "openssl"
require "securerandom"
require "base64"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# Pre-seeded principals (see db/seeds.rb). StubIdp parses the token directly.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"
# The agent id is a UUID, not a readable slug: `kiosk.action_log.agent_id`,
# every `kiosk.*_mandates.agent_id` and `kiosk.current_agent_id()` are all typed
# `uuid` in the canonical schema, so a stub identity carrying anything else is one
# the shipped tables cannot store (T-088 found it by being the first writer to try).
AGENT_A    = "a0000000-0000-0000-0000-000000000001"
AGENT_B    = "a0000000-0000-0000-0000-000000000002"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-#{AGENT_A}:r-customer"
TOKEN_B    = "agent:u-#{BOB_UUID}:a-#{AGENT_B}:r-customer"

# Seeded staff for the roles-from-IdP escalation beats. Only the owner is
# staff now (no stylist roster); Alice is a plain customer.
OWNER_ID = "00000000-0000-0000-0000-0000000000a0"

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

# Mint an owner link over the role-carrying StubUserIdp session
# (X-Staff-Session), optionally trying to smuggle a wider role in the claim
# body. Returns [http, claimed_body]. Used to prove the owner scope is only
# reachable through a genuine owner session, and the claim body cannot widen it.
def link_as_owner(extra_claim_body = {})
  rc, link = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => OWNER_ID })
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

# ── Fixture: A books an appointment (target for cross-tenant probes) ──────────
rc, salons = get_json("/kiosk/salons", bearer(TOKEN_A))
abort "salons query failed (#{rc}): #{JSON.generate(salons)} — run rake demo:setup" unless rc == 200
salon_id = Array(salons).first&.fetch("salon_id")
abort "no salons seeded — run rake demo:setup" unless salon_id

rc, appt_a = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: "2026-10-01T09:00:00Z" },
  bearer(TOKEN_A),
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a)}" unless rc == 200
appt_id_a = appt_a["appointment_id"]

# ── CrossTenantRead — B must not see A's appointment ─────────────────────────
rc, b_appts = get_json("/kiosk/my_appointments", bearer(TOKEN_B))
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
  { salon_id: salon_id, slot: "2026-10-02T09:00:00Z", user_id: ALICE_UUID },
  bearer(TOKEN_B),
)
refused = rc == 400 && forged["code"] == "bad_request" && forged["detail"].to_s.include?("user_id")

# And the principal really does come from the token, not from anything the
# caller sent: B's LEGITIMATE booking lands under B and never under A.
rc_b, bobs = post_json(
  "/kiosk/book_appointment",
  { salon_id: salon_id, slot: "2026-10-02T10:00:00Z" },
  bearer(TOKEN_B),
)
appt_id_bob = bobs["appointment_id"]
rc_a, a_appts = get_json("/kiosk/my_appointments", bearer(TOKEN_A))
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
rc, _ = get_json("/kiosk/frobnicate", bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/nope", {}, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

# ── RetiredWire — the deleted 0.3 endpoints are GONE, not tombstoned ─────────
# T-074 = A was a hard cut. `POST /kiosk/query` now reaches the per-verb
# controller as a verb literally named "query", which nobody registered, so it
# answers the ordinary 404 — no privileged endpoint, no compatibility payload,
# no second conformance surface to attack.
retired = %w[query run].map do |name|
  rc_r, body_r = post_json("/kiosk/#{name}", { name: "salons" }, bearer(TOKEN_A))
  [rc_r == 404 && body_r["code"] == "not_found", "#{name}→#{rc_r}/#{body_r['code'].inspect}"]
end
record(results, "RetiredWire", retired.all? { |ok, _| ok },
       "0.3 endpoints #{retired.map(&:last).join(', ')} (want 404/\"not_found\")")

# ── MethodMismatch — a GET at an action's path is 405, never a silent 404 ────
# The resource EXISTS; answering 404 would be a lie about it, and a caller that
# read 404 as "this operator cannot do that" would give up on a verb it could
# have called correctly.
uri405 = URI("#{SERVER}/kiosk/book_appointment")
res405 = Net::HTTP.new(uri405.host, uri405.port)
                  .request(Net::HTTP::Get.new(uri405, bearer(TOKEN_A)))
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

# CustomerCannotMintStaffLink — a CUSTOMER (Alice) tries to mint an assistant
# link over the staff channel (X-Staff-Session naming her). StubUserIdp resolves
# ONLY staff (staff_role present), so a customer session yields no identity and
# the mint is REJECTED (not 201). The owner scope is unreachable from a customer.
rc, _link = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => ALICE_UUID })
record(results, "CustomerCannotMintStaffLink",
       rc != 201,
       "customer staff-link mint → #{rc} (want NOT 201; non-staff session yields no link)")

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
  { salon_id: salon_id, slot: "2026-10-03T09:00:00Z" },
  bearer(TOKEN_B),
)
appt_id_b3 = appt_b3["appointment_id"]

rc, cal = get_json("/kiosk/salon_calendar", bearer(TOKEN_A))
rows = Array(cal)
own_ids     = rows.reject { |r| r["summary"] }.map { |r| r["id"] }
own_only    = !own_ids.include?(appt_id_b3)
no_forecast = rows.none? { |r| r["summary"] == "forecast" }
record(results, "CustomerCalendarStaysOwnScoped",
       rc == 200 && rc_b3 == 200 && own_only && no_forecast,
       "customer salon_calendar: #{rows.size} rows #{own_ids.inspect}, excludes B's #{appt_id_b3.inspect} " \
       "(own_only=#{own_only}), forecast_hidden=#{no_forecast}")

# ── SelfAssertedStaffSessionForgery (K-555) — in-process, PRODUCTION-config ────
# The HUMAN sibling of the K-539 agent-stub forgery. stylish's StubUserIdp maps a
# self-asserted `X-Staff-Session: <user_id>` header to a role-carrying HUMAN
# identity (the SSO/Okta stand-in) — so on the wire it SELF-GRANTS a staff role.
# This suite drives a server booted in RAILS_ENV=development, where that stub is
# INTENTIONALLY live (demo:roles walks the role-carrying session, and the
# CustomerCannotMintStaffLink / OwnerLinkIgnoresForgedClaimBody beats above
# exercise it over the wire) — so the DEV wire cannot demonstrate the block. This
# beat exercises the REAL shipped StubUserIdp guard in-process against a stubbed
# PRODUCTION Rails.env: a forged `X-Staff-Session` naming the seeded owner must
# resolve to NO identity under production (→ POST /kiosk/auth/link raises 401,
# self-grant impossible), while development still resolves the staff identity.
# Over-the-wire production proof: deploy/production-smoke.sh Assertion 6. Unit
# proof: kiosk-test-support spec/stub_user_idp_env_gate_spec.rb (bearer variant).
self_asserted_staff_forgery = lambda do
  require "kiosk"
  require File.expand_path("../app/services/stub_user_idp", __dir__)

  # The redteam client boots no Rails app, so provide a controllable Rails.env
  # and a minimal ActiveRecord shim (the dev branch does a staff-row lookup).
  unless defined?(Rails)
    env_klass = Struct.new(:name) do
      def local? = %w[development test].include?(name)
      def to_s = name.to_s
    end
    rails = Module.new do
      class << self
        attr_accessor :env
      end
    end
    Object.const_set(:Rails, rails)
    Object.const_set(:RedteamEnvShim, env_klass)
  end
  unless defined?(ActiveRecord)
    Object.const_set(:ActiveRecord, Module.new)
    base = Class.new do
      def self.connection
        @connection ||= Object.new.tap do |c|
          def c.quote(value) = "'#{value}'"
          def c.execute(_sql) = [{ "id" => OWNER_ID, "staff_role" => "owner" }]
        end
      end
    end
    ActiveRecord.const_set(:Base, base)
  end

  forged = Struct.new(:headers).new({ "X-Staff-Session" => OWNER_ID })
  idp = StubUserIdp.new

  Rails.env = RedteamEnvShim.new("production")
  prod_identity = idp.verify(forged)
  Rails.env = RedteamEnvShim.new("development")
  dev_identity = idp.verify(forged)

  blocked = prod_identity.nil? && dev_identity && dev_identity.role.to_s == "owner"
  detail =
    if blocked
      "forged `X-Staff-Session` → NO identity under production config (dev still self-grants role=owner, so the guard — not a broken stub — is what blocks)"
    elsif prod_identity
      "K-555 REGRESSION: forged X-Staff-Session self-granted role=#{prod_identity.role} under PRODUCTION config"
    else
      "unexpected: development branch rejected the staff stub (demo:roles would break): #{dev_identity.inspect}"
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
  ["unknown salon_id",        { salon_id: 999_999, slot: "2026-10-01T09:00:00Z" }],
  ["missing salon_id",        { slot: "2026-10-01T09:00:00Z" }],
  ["unknown service_id",      { salon_id: :seeded, slot: "2026-10-01T09:00:00Z", service_id: 999_999 }],
].freeze
PG_INTERNALS = ["PG::", "NotNullViolation", "RecordInvalid", "DatatypeMismatch", "violates not-null"].freeze

bad_failures = []
BAD_INPUTS.each do |label, args|
  body = args.dup
  body[:salon_id] = salon_id if body[:salon_id] == :seeded
  rc, resp = post_json("/kiosk/book_appointment", body, bearer(TOKEN_A))
  code = resp.is_a?(Hash) ? resp["code"] : nil
  leak = PG_INTERNALS.find { |needle| JSON.generate(resp).include?(needle) }
  next if rc == 400 && code == "bad_request" && leak.nil?

  bad_failures << "#{label} → HTTP #{rc} code=#{code.inspect}" \
                  "#{leak ? " LEAKS #{leak.inspect}" : ""}#{rc == 200 ? " (SILENTLY BOOKED)" : ""}"
end

# POSITIVE CONTROLS — without them the block above would pass against a handler
# that simply refused every booking. A bare salon booking (no service_id at all)
# is legitimate and the descriptor promises it; a full booking must still
# capture the service price the forecast is summed from.
rc_bare, bare = post_json("/kiosk/book_appointment",
  { salon_id: salon_id, slot: "2026-10-03T09:00:00Z" }, bearer(TOKEN_A))
bad_failures << "CONTROL bare salon booking → HTTP #{rc_bare} #{JSON.generate(bare)[0, 160]}" unless rc_bare == 200

rc_menu, menu = get_json("/kiosk/service_menu", bearer(TOKEN_A))
service = Array(menu).find { |r| r["price_cents"].to_i.positive? }
rc_full, full = post_json("/kiosk/book_appointment",
  { salon_id: salon_id, slot: "2026-10-04T09:00:00Z",
    service_id: service && service["service_id"] }, bearer(TOKEN_A))
unless rc_menu == 200 && rc_full == 200 && full["price_cents"].to_i == service["price_cents"].to_i
  bad_failures << "CONTROL priced booking → HTTP #{rc_full} price_cents=#{full["price_cents"].inspect} " \
                  "(want #{service && service["price_cents"].inspect})"
end

record(results, "UntypedBookingInput", bad_failures.empty?,
       bad_failures.empty? ? "#{BAD_INPUTS.size} bad-input shapes → typed 400 bad_request, no PG internals; bare + priced bookings still succeed" : bad_failures.join(" | "))

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
