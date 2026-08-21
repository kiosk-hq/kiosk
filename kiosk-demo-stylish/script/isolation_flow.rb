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
# THE TWO PRINCIPALS ARE EARNED, NOT ASSERTED (T-104). This driver used to hand
# itself both identities by writing them down — `agent:u-<uuid>:a-<uuid>:r-customer`
# — which a dev-only parser inside the demo's own agent-IdP turned into an
# authenticated identity at whatever role the string asked for. That parser is
# deleted and nothing replaced it, so each principal here runs the shipped
# ceremony instead (script/bound_assistant.rb: Equihash-tolled `/auth/register` →
# the human's real Devise sign-in → `/auth/link` → `/auth/claim`). A and B hold
# SEPARATE Devise sessions because they are separate humans.
#
# The claim is a REBIND, which is why the assertions below still read as "A's
# appointments" and "B's": the headless account `/auth/register` minted is
# remapped onto the seeded human, so each assistant's `user_id` IS its human's
# seeded uuid. The `agent_id`, by contrast, is MINTED and cannot be chosen —
# `kiosk.agents.id`, every `kiosk.*_mandates.agent_id` and
# `kiosk.current_agent_id()` are typed `uuid` in the canonical schema, so a
# driver naming its own agent id was naming a shape the shipped tables may not
# be able to store (K-829/K-830).
#
# Users are pre-seeded by demo:setup (db/seeds.rb); the credentials arrive in
# the environment from the rake task, never as literals here.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3005 \
#   KIOSK_ISSUER=http://127.0.0.1:3005 \
#   ALICE_EMAIL=alice@example.com BOB_EMAIL=bob@example.com \
#   DEMO_PASSWORD=… bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "json"
require "net/http"
require "uri"

require_relative "bound_assistant"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER", SERVER)

# The seeded humans behind the two assistants (db/seeds.rb). Emails and password
# come from the environment — db/seeds.rb owns them and the rake task passes
# them through, the same way demo:binding passes HOLDER_EMAIL/HOLDER_PASSWORD. A
# password literal in a driver is a second place for it to be true.
ALICE_EMAIL = ENV.fetch("ALICE_EMAIL")
BOB_EMAIL   = ENV.fetch("BOB_EMAIL")
PASSWORD    = ENV.fetch("DEMO_PASSWORD")

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

# ── Step 0: two principals, each EARNED through the shipped ceremony ─────────
alice = bind_assistant(server: SERVER, issuer: ISSUER, email: ALICE_EMAIL, password: PASSWORD)
bob   = bind_assistant(server: SERVER, issuer: ISSUER, email: BOB_EMAIL,   password: PASSWORD)
STDERR.puts "  A bound: agent=#{alice.agent_id} user=#{alice.user_id} role=#{alice.claims["role"].inspect}"
STDERR.puts "  B bound: agent=#{bob.agent_id} user=#{bob.user_id} role=#{bob.claims["role"].inspect}"

# The whole file asserts a boundary BETWEEN two principals. If the ceremony ever
# handed both assistants the same account the exclusions below would pass while
# proving nothing, so say so here rather than let a green run lie.
abort "both assistants bound to the SAME account (#{alice.user_id}) — no boundary to test" \
  if alice.user_id == bob.user_id
abort "both assistants share an agent id (#{alice.agent_id}) — registration is not minting" \
  if alice.agent_id == bob.agent_id

# ── Step 1: Get salon_id from the open catalogue ─────────────────────────────
# salons query is open-read; any authenticated principal may browse.
rc, salons_resp = get_json(
  "#{SERVER}/kiosk/salons",
  {},
  alice.bearer,
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
  alice.bearer,
)
abort "A book_appointment failed (#{rc}): #{JSON.generate(appt_a_resp)}" unless rc == 200

appt_id_a = appt_a_resp["appointment_id"]
abort "A's appointment_id missing from response: #{JSON.generate(appt_a_resp)}" unless appt_id_a

STDERR.puts "  A booked: appt_id=#{appt_id_a}"

# ── Step 3: B queries my_appointments — must NOT contain aA (Assertion 1) ────
rc, b_appts_resp = get_json(
  "#{SERVER}/kiosk/my_appointments",
  {},
  bob.bearer,
)
abort "B my_appointments failed (#{rc}): #{JSON.generate(b_appts_resp)}" unless rc == 200

b_appt_ids = Array(b_appts_resp).map { |r| r["id"] }
STDERR.puts "  B my_appointments: #{b_appt_ids.inspect}"

# ── Step 4a: B calls book_appointment with a FORGED user_id arg (Assertion 2a) ─
#
# B's Authorization token identifies B; the forged arg supplies A's UUID — read
# off A's OWN bound token rather than written down here, so the forgery names
# the account this run actually books under.
# On the 0.4 wire this is REFUSED before the handler runs:
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
    user_id:  alice.user_id, # adversarial: B supplies A's user_id in args
  },
  bob.bearer,
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
  bob.bearer,
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
  bob.bearer,
)
abort "B my_appointments (after) failed (#{rc}): #{JSON.generate(b_appts_after_resp)}" unless rc == 200

b_appt_ids_after = Array(b_appts_after_resp).map { |r| r["id"] }
STDERR.puts "  B my_appointments (after own booking): #{b_appt_ids_after.inspect}"

# ── Step 6: A queries my_appointments after B's booking ──────────────────────
# A must NOT see B's appointment (cross-check for Assertion 2).
rc, a_appts_resp = get_json(
  "#{SERVER}/kiosk/my_appointments",
  {},
  alice.bearer,
)
abort "A my_appointments (after) failed (#{rc}): #{JSON.generate(a_appts_resp)}" unless rc == 200

a_appt_ids_after = Array(a_appts_resp).map { |r| r["id"] }
STDERR.puts "  A my_appointments (after B's booking): #{a_appt_ids_after.inspect}"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:        alice.user_id,
  user_id_b:        bob.user_id,
  agent_id_a:       alice.agent_id,
  agent_id_b:       bob.agent_id,
  appt_id_a:        appt_id_a,
  appt_id_b:        appt_id_b,
  b_appt_ids:       b_appt_ids,
  b_appt_ids_after: b_appt_ids_after,
  a_appt_ids_after: a_appt_ids_after,
  forged_refusal:   [forged_rc, forged_resp["code"], forged_resp["detail"]],
)
