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
#   ForgedUserId       — agent-supplied user_id in book_appointment args ignored
#   MissingAuth        — a request with no Authorization → 401
#   GarbageToken       — an unparseable bearer token → 401
#   UnknownQuery       — an unregistered query name → 404
#   UnknownAction      — an unregistered action name → 404
#   CustomerCannotSelfSelectOwnerAtBinding — a self-registered CUSTOMER cannot
#     smuggle an `owner` role into the register/claim body; the role is pinned
#     by the provider (registration_role), so the token stays `customer`
#   CustomerCalendarStaysOwnScoped — that customer's agent sees only its OWN
#     bookings (no whole-book, no forecast) in salon_calendar — the role gate
#     is provider-controlled and un-bypassable
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
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-alice-redteam:r-customer"
TOKEN_B    = "agent:u-#{BOB_UUID}:a-bob-redteam:r-customer"

# Seeded staff for the roles-from-IdP escalation beats. Only the owner is
# staff now (no stylist roster); Alice is a plain customer.
OWNER_ID = "00000000-0000-0000-0000-0000000000a0"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path, headers = {})
  uri = URI("#{SERVER}#{path}")
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
rc, salons = post_json("/kiosk/query", { name: "salons" }, bearer(TOKEN_A))
abort "salons query failed (#{rc}): #{JSON.generate(salons)} — run rake demo:setup" unless rc == 200
salon_id = (salons["rows"] || []).first&.fetch("salon_id")
abort "no salons seeded — run rake demo:setup" unless salon_id

rc, appt_a = post_json(
  "/kiosk/run",
  { name: "book_appointment", salon_id: salon_id, slot: "2026-10-01T09:00:00Z" },
  bearer(TOKEN_A),
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a)}" unless rc == 200
appt_id_a = appt_a.dig("value", "appointment_id")

# ── CrossTenantRead — B must not see A's appointment ─────────────────────────
rc, b_appts = post_json("/kiosk/query", { name: "my_appointments" }, bearer(TOKEN_B))
b_ids = (b_appts["rows"] || []).map { |r| r["id"] }
record(results, "CrossTenantRead",
       rc == 200 && !b_ids.include?(appt_id_a),
       "B's my_appointments #{b_ids.inspect} excludes A's #{appt_id_a}")

# ── ForgedUserId — B books with A's user_id in args; server must ignore it ────
rc, forged = post_json(
  "/kiosk/run",
  { name: "book_appointment", salon_id: salon_id, slot: "2026-10-02T09:00:00Z", user_id: ALICE_UUID },
  bearer(TOKEN_B),
)
appt_id_forged = forged.dig("value", "appointment_id")
# The forged appointment must NOT surface in A's list (it belongs to B).
rc_a, a_appts = post_json("/kiosk/query", { name: "my_appointments" }, bearer(TOKEN_A))
a_ids = (a_appts["rows"] || []).map { |r| r["id"] }
record(results, "ForgedUserId",
       rc == 200 && rc_a == 200 && !a_ids.include?(appt_id_forged),
       "A's list #{a_ids.inspect} excludes B's forged appt #{appt_id_forged.inspect}")

# ── MissingAuth — no Authorization header → 401 ──────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "salons" })
record(results, "MissingAuth", rc == 401, "unauthenticated request → #{rc} (want 401)")

# ── GarbageToken — unparseable bearer → 401 ──────────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "salons" }, bearer("not-a-real-token"))
record(results, "GarbageToken", rc == 401, "garbage token → #{rc} (want 401)")

# ── UnknownQuery — unregistered query name → 404 ─────────────────────────────
rc, _ = post_json("/kiosk/query", { name: "frobnicate" }, bearer(TOKEN_A))
record(results, "UnknownQuery", rc == 404, "unknown query → #{rc} (want 404)")

# ── UnknownAction — unregistered action name → 404 ───────────────────────────
rc, _ = post_json("/kiosk/run", { name: "nope" }, bearer(TOKEN_A))
record(results, "UnknownAction", rc == 404, "unknown action → #{rc} (want 404)")

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
  "/kiosk/run",
  { name: "book_appointment", salon_id: salon_id, slot: "2026-10-03T09:00:00Z" },
  bearer(TOKEN_B),
)
appt_id_b3 = appt_b3.dig("value", "appointment_id")

rc, cal = post_json("/kiosk/query", { name: "salon_calendar" }, bearer(TOKEN_A))
rows = (cal["rows"] || [])
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
  require File.expand_path("../lib/stub_user_idp", __dir__)

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
