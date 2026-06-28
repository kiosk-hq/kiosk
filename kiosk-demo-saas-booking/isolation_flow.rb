# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver (R1 Phase 1 Task 3).
#
# Proves saas-booking app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — my_appointments exclusion:
#     Principal A books appointment aA.
#     Principal B queries my_appointments → rows must NOT contain aA.
#     (B sees only B's appointments; A's appointment is excluded.)
#
#   Assertion 2 — forged user_id arg ignored on book_appointment:
#     Principal B calls run book_appointment with a forged user_id arg (A's UUID).
#     → The created appointment's DB user_id is B (server uses kiosk.current_user_id(),
#       ignores agent-supplied user_id). Verified via DB SELECT in the rake task.
#     Cross-check: A's my_appointments does NOT contain B's forged appointment.
#
#   Note — book_appointment cross-resource ownership denial (not applicable):
#     book_appointment takes salon_id (open catalogue, any authenticated principal
#     may browse). There is no user-owned resource that one principal can target on
#     behalf of another via book_appointment args. No ownership-denial assertion
#     applies to this surface. Documented honestly rather than fabricated.
#
# StubIdp shape: "agent:u-<uuid>:a-<agent_id>:r-<role>" — no RSA registration
# needed. Users are pre-seeded by demo:setup (db/seeds.rb).
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3001 \
#   KIOSK_ISSUER=http://127.0.0.1:3001 \
#   bundle exec ruby isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

# Pre-seeded principals (see db/seeds.rb). StubIdp parses the token
# directly — no RSA key registration needed for the saas-booking demo shape.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"

# Distinct agent IDs so isolation_flow runs don't clash with bin/demo sessions.
TOKEN_A = "agent:u-#{ALICE_UUID}:a-alice-isolation:r-customer"
TOKEN_B = "agent:u-#{BOB_UUID}:a-bob-isolation:r-customer"

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Step 1: Get salon_id from the open catalogue ─────────────────────────────
# salons query is open-read; any authenticated principal may browse.
rc, salons_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "salons" } },
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "salons query failed (#{rc}): #{JSON.generate(salons_resp)}" unless rc == 200

salon_id = (salons_resp["rows"] || []).first&.fetch("id")
abort "no salons found — run bundle exec rake demo:setup first" unless salon_id

STDERR.puts "  salon_id=#{salon_id}"

# ── Step 2: A books appointment aA ───────────────────────────────────────────
rc, appt_a_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:     "book_appointment",
      salon_id: salon_id,
      slot:     "2026-09-01T10:00:00Z",
    },
  },
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a_resp)}" unless rc == 200

appt_id_a = appt_a_resp.dig("value", "appointment_id")
abort "A's appointment_id missing from response: #{JSON.generate(appt_a_resp)}" unless appt_id_a

STDERR.puts "  A booked: appt_id=#{appt_id_a}"

# ── Step 3: B queries my_appointments — must NOT contain aA (Assertion 1) ────
rc, b_appts_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_appointments" } },
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B my_appointments failed (#{rc}): #{JSON.generate(b_appts_resp)}" unless rc == 200

b_appt_ids = (b_appts_resp["rows"] || []).map { |r| r["id"] }
STDERR.puts "  B my_appointments: #{b_appt_ids.inspect}"

# ── Step 4: B calls book_appointment with FORGED user_id arg (Assertion 2) ───
# B's Authorization token identifies B (BOB_UUID). The forged user_id arg
# supplies A's UUID. The server's book_appointment action ignores args[:user_id]
# and reads the identity from kiosk.current_user_id() — so the created
# appointment must belong to B, not A.
rc, forged_resp = post_json(
  "#{SERVER}/kiosk/exec",
  {
    command: "run",
    body: {
      name:     "book_appointment",
      salon_id: salon_id,
      slot:     "2026-09-02T11:00:00Z",
      user_id:  ALICE_UUID, # adversarial: B supplies A's user_id in args
    },
  },
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B forged book_appointment failed (#{rc}): #{JSON.generate(forged_resp)}" unless rc == 200

appt_id_b = forged_resp.dig("value", "appointment_id")
abort "B's forged appointment_id missing from response: #{JSON.generate(forged_resp)}" unless appt_id_b

STDERR.puts "  B booked (forged user_id): appt_id=#{appt_id_b}"

# ── Step 5: B queries my_appointments after its own booking (positive control) ─
# Assertion 1b positive control: B must see its OWN appointment appt_id_b in
# my_appointments. This proves that Assertion 1's exclusion is not vacuous:
# if my_appointments always returned empty for B, the exclusion of aA would
# pass spuriously. Seeing appt_id_b here confirms the query is live for B.
rc, b_appts_after_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_appointments" } },
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B my_appointments (after) failed (#{rc}): #{JSON.generate(b_appts_after_resp)}" unless rc == 200

b_appt_ids_after = (b_appts_after_resp["rows"] || []).map { |r| r["id"] }
STDERR.puts "  B my_appointments (after own booking): #{b_appt_ids_after.inspect}"

# ── Step 6: A queries my_appointments after B's forged booking ───────────────
# A must NOT see B's forged appointment (cross-check for Assertion 2).
rc, a_appts_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "my_appointments" } },
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "A my_appointments (after) failed (#{rc}): #{JSON.generate(a_appts_resp)}" unless rc == 200

a_appt_ids_after = (a_appts_resp["rows"] || []).map { |r| r["id"] }
STDERR.puts "  A my_appointments (after B's forged booking): #{a_appt_ids_after.inspect}"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:        ALICE_UUID,
  user_id_b:        BOB_UUID,
  appt_id_a:        appt_id_a,
  appt_id_b:        appt_id_b,
  b_appt_ids:       b_appt_ids,
  b_appt_ids_after: b_appt_ids_after,
  a_appt_ids_after: a_appt_ids_after,
)
