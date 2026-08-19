# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver.
#
# Proves stylish app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — my_appointments exclusion:
#     Principal A books appointment aA.
#     Principal B queries my_appointments → rows must NOT contain aA.
#     (B sees only B's appointments; A's appointment is excluded.)
#
#   Assertion 2 — the principal is not an input to book_appointment:
#     Principal B calls book_appointment with a forged user_id arg (A's UUID).
#     → 400 bad_request naming user_id: `book_appointment` publishes
#       `additionalProperties: false` and does not declare `user_id`, so the
#       declared input contract refuses the forgery before the handler runs.
#     And, on a LEGITIMATE booking by B, the created appointment's DB user_id is
#       B — ownership is taken from kiosk.current_user_id(), which the refusal
#       alone does not prove. Verified via DB SELECT in the rake task.
#     Cross-check: A's my_appointments does NOT contain B's appointment.
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
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "json"
require "net/http"
require "uri"

SERVER = ENV.fetch("SERVER_URL")

# Pre-seeded principals (see db/seeds.rb). StubIdp parses the token
# directly — no RSA key registration needed for the stylish demo shape.
ALICE_UUID = "00000000-0000-0000-0000-000000000001"
BOB_UUID   = "00000000-0000-0000-0000-000000000002"

# Distinct agent IDs so isolation_flow runs don't clash with bin/demo sessions.
TOKEN_A = "agent:u-#{ALICE_UUID}:a-alice-isolation:r-customer"
TOKEN_B = "agent:u-#{BOB_UUID}:a-bob-isolation:r-customer"

# THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` with its arguments
# as the JSON body; a query is `GET <endpoint>/<query-name>` with its arguments
# in the query string. There is no `name` field and no /query or /run endpoint.
# A success body IS the result — a bare array from a non-paginating query, the
# action's own object from an action — and an error is an RFC 9457 problem
# document whose branch point is the top-level `code`.
def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, params = {}, headers = {})
  uri = URI(url)
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri, headers)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Step 1: Get salon_id from the open catalogue ─────────────────────────────
# salons query is open-read; any authenticated principal may browse.
rc, salons_resp = get_json(
  "#{SERVER}/kiosk/salons",
  {},
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "salons query failed (#{rc}): #{JSON.generate(salons_resp)}" unless rc == 200

salon_id = Array(salons_resp).first&.fetch("salon_id")
abort "no salons found — run bundle exec rake demo:setup first" unless salon_id

STDERR.puts "  salon_id=#{salon_id}"

# ── Step 2: A books appointment aA ───────────────────────────────────────────
rc, appt_a_resp = post_json(
  "#{SERVER}/kiosk/book_appointment",
  {
    salon_id: salon_id,
    slot:     "2026-09-01T10:00:00Z",
  },
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a_resp)}" unless rc == 200

appt_id_a = appt_a_resp["appointment_id"]
abort "A's appointment_id missing from response: #{JSON.generate(appt_a_resp)}" unless appt_id_a

STDERR.puts "  A booked: appt_id=#{appt_id_a}"

# ── Step 3: B queries my_appointments — must NOT contain aA (Assertion 1) ────
rc, b_appts_resp = get_json(
  "#{SERVER}/kiosk/my_appointments",
  {},
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B my_appointments failed (#{rc}): #{JSON.generate(b_appts_resp)}" unless rc == 200

b_appt_ids = Array(b_appts_resp).map { |r| r["id"] }
STDERR.puts "  B my_appointments: #{b_appt_ids.inspect}"

# ── Step 4a: B calls book_appointment with a FORGED user_id arg (Assertion 2a) ─
#
# B's Authorization token identifies B (BOB_UUID); the forged arg supplies A's
# UUID. On the 0.4 wire this is REFUSED before the handler runs:
# `book_appointment` publishes `additionalProperties: false` and does not
# declare `user_id` — the principal is not one of its inputs — so the declared
# input contract answers a typed 400 naming the parameter. (Through 0.3 the
# argument was accepted and silently ignored; refusing it is the stricter answer
# and the one the published contract requires.)
forged_rc, forged_resp = post_json(
  "#{SERVER}/kiosk/book_appointment",
  {
    salon_id: salon_id,
    slot:     "2026-09-02T11:00:00Z",
    user_id:  ALICE_UUID, # adversarial: B supplies A's user_id in args
  },
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
STDERR.puts "  B book_appointment with a forged user_id → #{forged_rc} #{forged_resp["code"].inspect}"

# ── Step 4b: B books LEGITIMATELY (Assertion 2b) ─────────────────────────────
# The half the refusal does not by itself prove: ownership is taken from the
# AUTHENTICATED identity. The rake task reads this row back and asserts
# appointments.user_id == B.
rc, appt_b_resp = post_json(
  "#{SERVER}/kiosk/book_appointment",
  {
    salon_id: salon_id,
    slot:     "2026-09-02T12:00:00Z",
  },
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B book_appointment failed (#{rc}): #{JSON.generate(appt_b_resp)}" unless rc == 200

appt_id_b = appt_b_resp["appointment_id"]
abort "B's appointment_id missing from response: #{JSON.generate(appt_b_resp)}" unless appt_id_b

STDERR.puts "  B booked (owner from token): appt_id=#{appt_id_b}"

# ── Step 5: B queries my_appointments after its own booking (positive control) ─
# Assertion 1b positive control: B must see its OWN appointment appt_id_b in
# my_appointments. This proves that Assertion 1's exclusion is not vacuous:
# if my_appointments always returned empty for B, the exclusion of aA would
# pass spuriously. Seeing appt_id_b here confirms the query is live for B.
rc, b_appts_after_resp = get_json(
  "#{SERVER}/kiosk/my_appointments",
  {},
  { "Authorization" => "Bearer #{TOKEN_B}" },
)
abort "B my_appointments (after) failed (#{rc}): #{JSON.generate(b_appts_after_resp)}" unless rc == 200

b_appt_ids_after = Array(b_appts_after_resp).map { |r| r["id"] }
STDERR.puts "  B my_appointments (after own booking): #{b_appt_ids_after.inspect}"

# ── Step 6: A queries my_appointments after B's booking ──────────────────────
# A must NOT see B's appointment (cross-check for Assertion 2).
rc, a_appts_resp = get_json(
  "#{SERVER}/kiosk/my_appointments",
  {},
  { "Authorization" => "Bearer #{TOKEN_A}" },
)
abort "A my_appointments (after) failed (#{rc}): #{JSON.generate(a_appts_resp)}" unless rc == 200

a_appt_ids_after = Array(a_appts_resp).map { |r| r["id"] }
STDERR.puts "  A my_appointments (after B's booking): #{a_appt_ids_after.inspect}"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:        ALICE_UUID,
  user_id_b:        BOB_UUID,
  appt_id_a:        appt_id_a,
  appt_id_b:        appt_id_b,
  b_appt_ids:       b_appt_ids,
  b_appt_ids_after: b_appt_ids_after,
  a_appt_ids_after: a_appt_ids_after,
  forged_refusal:   [forged_rc, forged_resp["code"], forged_resp["detail"]],
)
