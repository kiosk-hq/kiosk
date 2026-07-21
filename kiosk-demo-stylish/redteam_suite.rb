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
#   StylistCannotSelfSelectOwnerAtBinding — a stylist linking an assistant
#     cannot smuggle an `owner` role into the claim body; the role is sourced
#     from the bound human's IdP, so the token stays `stylist` (roles-from-IdP)
#   StylistCalendarStaysStylistScoped — that stylist's agent sees only its own
#     chairs (no whole-book, no revenue) in salon_calendar — the role gate is
#     provider-controlled and un-bypassable
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 \
#   KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby redteam_suite.rb
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

# Seeded staff for the roles-from-IdP escalation beats.
OWNER_ID    = "00000000-0000-0000-0000-0000000000a0"
STYLIST1_ID = "00000000-0000-0000-0000-0000000000b1"

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

# Link an assistant as a staff member over the role-carrying StubUserIdp
# session (X-Staff-Session), optionally trying to smuggle a wider role in the
# claim body. Returns [http, claimed_body].
def link_as_staff(staff_user_id, extra_claim_body = {})
  rc, link = post_json("/kiosk/auth/link", {}, { "X-Staff-Session" => staff_user_id })
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
salon_id = (salons["rows"] || []).first&.fetch("id")
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
# A stylist's agent must NOT be able to obtain owner-scope. The role is
# sourced from the bound human's IdP at link time — never self-selected by the
# agent — and salon_calendar's WHERE is provider-controlled.

# StylistAgentGetsStylistRole — link as a stylist while trying to smuggle an
# `owner` role (and role/allowed_roles) into the claim body. The bound token
# must still carry `stylist` — the claim body role is ignored; the IdP wins.
rc, claimed = link_as_staff(STYLIST1_ID, role: "owner", allowed_roles: ["owner"], requested_role: "owner")
stylist_token = claimed["access_token"].to_s
seg = stylist_token.split(".")[1].to_s
role_claim = (JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))["role"] rescue nil)
record(results, "StylistCannotSelfSelectOwnerAtBinding",
       rc == 201 && role_claim == "stylist",
       "stylist link with forged owner body → token role #{role_claim.inspect} (want \"stylist\", claim body ignored)")

# StylistCalendarStaysStylistScoped — the stylist's agent calls salon_calendar;
# it must see ONLY its own chairs and NO revenue total (owner-only), even
# though it just tried to claim owner. The role gate is un-bypassable.
rc, cal = post_json("/kiosk/query", { name: "salon_calendar" }, bearer(stylist_token))
rows = (cal["rows"] || [])
own_only     = rows.all? { |r| r["stylist_id"] == STYLIST1_ID }
no_revenue   = rows.none? { |r| r["summary"] == "revenue" }
record(results, "StylistCalendarStaysStylistScoped",
       rc == 200 && own_only && no_revenue && !rows.empty?,
       "stylist salon_calendar: #{rows.size} rows, own_only=#{own_only}, revenue_hidden=#{no_revenue}")

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
