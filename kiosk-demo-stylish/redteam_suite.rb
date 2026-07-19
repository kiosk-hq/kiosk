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

SERVER = ENV.fetch("SERVER_URL")

# Pre-seeded principals (see db/seeds.rb). StubIdp parses the token directly.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"
TOKEN_A    = "agent:u-#{ALICE_UUID}:a-alice-redteam:r-customer"
TOKEN_B    = "agent:u-#{BOB_UUID}:a-bob-redteam:r-customer"

def post_json(path, body, headers = {})
  uri = URI("#{SERVER}#{path}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def bearer(token)
  { "Authorization" => "Bearer #{token}" }
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
