# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver.
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result — a bare array from a non-paginating
# query, the action's own object from an action — and an error is an RFC 9457
# problem document whose branch point is the TOP-LEVEL `code`.
#
# Proves hoteling app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — confirm_booking ownership denial (Gate-1 isolated):
#     Principal A reserves room → booking_id rA.
#     Principal B's pay call creates a settlement whose cart references rA
#     (satisfies Gate-2) then calls POST /kiosk/confirm_booking {booking_id: rA}.
#     → Must be denied (HTTP 403). Gate-1 WHERE id=rA AND
#       user_id=kiosk.current_user_id() AND status='reserved' finds nothing
#       because rA.user_id = A ≠ B.
#     The 403 genuinely isolates Gate-1 ownership: Gate-2 (payment) is
#     satisfied by B before the attempt, so payment cannot be the blocker.
#
#   Assertion 2 — my_bookings: exclusion + positive control:
#     2a: B's my_bookings must NOT contain rA.
#     2b (positive control): B's my_bookings must contain rB (B's own booking),
#         proving the exclusion is not vacuous.
#
#   Assertion 3 — the principal is NOT an input, in two halves:
#     3a: B calls reserve_room with a forged user_id arg (A's UUID) → 400
#         bad_request naming user_id. `reserve_room` publishes
#         `additionalProperties: false` and does not declare `user_id`, so on
#         the 0.4 wire the declared input contract refuses the forgery BEFORE
#         the handler runs. (Through 0.3 the argument was accepted and silently
#         ignored; refusing it is the stricter answer and the one the published
#         contract requires.)
#     3b: B's LEGITIMATE booking has DB user_id = B — the property the refusal
#         alone does not prove, because ownership comes from
#         kiosk.current_user_id() and never from an argument. Verified by DB
#         SELECT in the rake task.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 \
#   KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby script/isolation_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.
# (The DB-row assertions run in the demo:isolation rake task, not here.)

require "date"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# ── helpers ──────────────────────────────────────────────────────────────────

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(url, headers = {})
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# One query call: the verb NAME is the path segment, its arguments are the
# query string.
def query_json(name, params = {}, headers = {})
  uri = URI("#{SERVER}/kiosk/#{name}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  get_json(uri.to_s, headers)
end

require_relative "equihash_register"

# Register a fresh principal through the proof-of-possession handshake, solving
# the Equihash register PoW transparently. The private key is returned so the
# principal can sign its own pay mandates.
# Returns [user_id, agent_id, token, key].
def register_principal(name:)
  key, reg = equihash_register(
    server: SERVER, issuer: ISSUER,
    get_json: method(:get_json), post_json: method(:post_json),
  )
  user_id  = reg.fetch("user_id")
  agent_id = reg.fetch("agent_id")
  token    = reg.fetch("access_token")
  STDERR.puts "  #{name}: registered user_id=#{user_id} agent_id=#{agent_id}"

  [user_id, agent_id, token, key]
end

# ── Date range ────────────────────────────────────────────────────────────────
# A uses +30..+33 days; B's own reserve uses +60..+63 to avoid conflicts.
CHECK_IN_A  = (Date.today + 30).to_s
CHECK_OUT_A = (Date.today + 33).to_s
CHECK_IN_B  = (Date.today + 60).to_s
CHECK_OUT_B = (Date.today + 63).to_s
NIGHTS      = 3

# ── Step 1: Register Principal A ─────────────────────────────────────────────
user_id_a, agent_id_a, token_a, _key_a = register_principal(name: "alice-hoteling")

# ── Step 2: Register Principal B ─────────────────────────────────────────────
user_id_b, agent_id_b, token_b, key_b = register_principal(name: "bob-hoteling")

# ── Step 3: A queries properties and availability ─────────────────────────────
rc_props_a, props_resp_a = query_json(
  "properties", {},
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A query properties failed (#{rc_props_a}): #{JSON.generate(props_resp_a)}" unless rc_props_a == 200

# A non-paginating query answers a BARE ARRAY — the rows, with nothing around
# them (0.4 retired the `{rows: …}` envelope).
all_props_a = Array(props_resp_a)
abort "No properties returned" if all_props_a.empty?
prop_a = all_props_a.first
prop_id_a = prop_a["property_id"]

rc_avail_a, avail_resp_a = query_json(
  "availability",
  { property_id: prop_id_a, check_in: CHECK_IN_A, check_out: CHECK_OUT_A },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A query availability failed (#{rc_avail_a}): #{JSON.generate(avail_resp_a)}" unless rc_avail_a == 200

avail_rows_a = Array(avail_resp_a)
abort "No available rooms for A" if avail_rows_a.empty?
room_a           = avail_rows_a.first
room_type_id_a   = room_a["room_type_id"]
room_type_name_a = room_a["name"]
STDERR.puts "  A will reserve #{room_type_name_a} at property #{prop_id_a}"

# ── Step 4: A reserves room → booking_id rA ──────────────────────────────────
rc_rsv_a, rsv_a_resp = post_json(
  "#{SERVER}/kiosk/reserve_room",
  { property_id: prop_id_a, room_type_id: room_type_id_a,
    check_in: CHECK_IN_A, check_out: CHECK_OUT_A },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reserve_room failed (#{rc_rsv_a}): #{JSON.generate(rsv_a_resp)}" unless rc_rsv_a == 200

# An action's success body IS its own object — the `{value: …}` wrapper is gone.
booking_id_a = rsv_a_resp["booking_id"]
total_cents_a = rsv_a_resp["total_cents"].to_i
abort "A's booking_id missing from response: #{JSON.generate(rsv_a_resp)}" unless booking_id_a
STDERR.puts "  A reserved: booking_id=#{booking_id_a} total=#{format("€%.2f", total_cents_a / 100.0)}"

# ── Step 5: B's pay creates a settlement referencing rA (satisfies Gate-2) ────
# B signs intent + cart + payment mandates with B's registered RSA key. The cart's
# line_items contain {booking_id: booking_id_a} so that Gate-2's jsonb-
# containment check passes for B.  settlements.user_id is written from
# the GUC (kiosk.current_user_id() = B), so s.user_id = B for Gate-2.
# After this step, only Gate-1 can deny B's confirm_booking(rA).
now_b        = Time.now.to_i
intent_id_b  = SecureRandom.uuid
cart_id_b    = SecureRandom.uuid
payment_id_b = SecureRandom.uuid
cap_b        = total_cents_a + 100

intent_b_payload = {
  id:               intent_id_b,
  user_id:          user_id_b,
  agent_id:         agent_id_b,
  iss:              ISSUER,
  scope:            "lodging",
  cap_amount_cents: cap_b,
  currency:         "eur",
  exp:              now_b + 600,
  iat:              now_b,
}
cart_b_payload = {
  id:                 cart_id_b,
  intent_mandate_id:  intent_id_b,
  user_id:            user_id_b,
  agent_id:           agent_id_b,
  iss:                ISSUER,
  line_items:         [{ sku: room_type_name_a, qty: NIGHTS, booking_id: booking_id_a }],
  total_amount_cents: total_cents_a,
  currency:           "eur",
  exp:                now_b + 600,
  iat:                now_b,
}
payment_b_payload = {
  id:              payment_id_b,
  cart_mandate_id: cart_id_b,
  user_id:         user_id_b,
  agent_id:        agent_id_b,
  iss:             ISSUER,
  payment_method:  "pm_demo",
  amount_cents:    total_cents_a,
  currency:        "eur",
  exp:             now_b + 600,
  iat:             now_b,
}

intent_b_jws  = JWT.encode(intent_b_payload,  key_b, "RS256")
cart_b_jws    = JWT.encode(cart_b_payload,    key_b, "RS256")
payment_b_jws = JWT.encode(payment_b_payload, key_b, "RS256")

rc_pay_b, pay_b_resp = post_json(
  "#{SERVER}/kiosk/pay",
  { intent_mandate_jws: intent_b_jws, cart_mandate_jws: cart_b_jws,
    payment_mandate_jws: payment_b_jws },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B pay (for rA) failed (#{rc_pay_b}): #{JSON.generate(pay_b_resp)}" unless rc_pay_b == 200
STDERR.puts "  B paid for rA: settlement_id=#{pay_b_resp["settlement_id"]} — Gate-2 now passes for B"

# ── Step 6: the principal is not an input (Assertion 3) ──────────────────────
# Two halves, because neither proves the other.
#
#   3a  B supplies `user_id: user_id_a` adversarially. On the 0.4 wire this is
#       REFUSED before the handler runs: `reserve_room` publishes
#       `additionalProperties: false` and does not declare `user_id` — the
#       principal is not one of its inputs — so the declared input contract
#       answers a typed 400 naming the parameter. Through 0.3 the argument was
#       accepted and silently ignored; refusing it is the stricter answer and
#       the one the published contract requires.
#   3b  B then reserves LEGITIMATELY, and the rake task reads the row back:
#       the INSERT takes the owner from kiosk.current_user_id() (B's UUID), not
#       from anything the caller sent. The refusal alone cannot show this —
#       a handler that read a forged owner would still be refused by the
#       schema — so the property is proved on a call that actually creates a row.
#
# Use a different date range (B_dates) to avoid A's booking blocking availability.
#
# First find an available room for B's date range.
rc_props_b, props_resp_b = query_json(
  "properties", {},
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B query properties failed (#{rc_props_b})" unless rc_props_b == 200

all_props_b = Array(props_resp_b)
# Find a property with availability for B's date range (any property).
prop_b = nil
room_b = nil
all_props_b.each do |p|
  rc_av, av_r = query_json(
    "availability",
    { property_id: p["property_id"], check_in: CHECK_IN_B, check_out: CHECK_OUT_B },
    { "Authorization" => "Bearer #{token_b}" },
  )
  next unless rc_av == 200
  rows = Array(av_r)
  if rows.any?
    prop_b = p
    room_b = rows.first
    break
  end
end
abort "B: no room available for #{CHECK_IN_B}..#{CHECK_OUT_B}" unless prop_b

# 3a — the forged principal is REFUSED by the published input contract.
rc_forge, forged_resp = post_json(
  "#{SERVER}/kiosk/reserve_room",
  {
    property_id:  prop_b["property_id"],
    room_type_id: room_b["room_type_id"],
    check_in:     CHECK_IN_B,
    check_out:    CHECK_OUT_B,
    user_id:      user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B reserve_room with a forged user_id → #{rc_forge} #{forged_resp["code"].inspect}"

# 3b — and B's LEGITIMATE booking is owned by B. Same room, same nights: the
# refusal above created nothing, so the inventory is untouched.
rc_rsv_b, rsv_b_resp = post_json(
  "#{SERVER}/kiosk/reserve_room",
  {
    property_id:  prop_b["property_id"],
    room_type_id: room_b["room_type_id"],
    check_in:     CHECK_IN_B,
    check_out:    CHECK_OUT_B,
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B reserve_room failed (#{rc_rsv_b}): #{JSON.generate(rsv_b_resp)}" unless rc_rsv_b == 200

booking_id_b = rsv_b_resp["booking_id"]
abort "B's booking_id missing: #{JSON.generate(rsv_b_resp)}" unless booking_id_b
STDERR.puts "  B reserved (owner from token): booking_id=#{booking_id_b}"

# ── Step 7: B queries my_bookings (Assertion 2) ───────────────────────────────
# B now has booking_id_b as its own row (Step 6). Two assertions:
#   2a exclusion:        b_booking_ids must NOT contain rA.
#   2b positive control: b_booking_ids MUST contain rB, proving
#     the exclusion is non-vacuous (the query actually returns B's own rows).
rc_b_bookings, b_bookings_resp = query_json(
  "my_bookings", {},
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_bookings failed (#{rc_b_bookings}): #{JSON.generate(b_bookings_resp)}" unless rc_b_bookings == 200

b_booking_ids = Array(b_bookings_resp).map { |r| r["booking_id"] }
STDERR.puts "  B my_bookings: #{b_booking_ids.inspect}"

# ── Step 8: B calls confirm_booking on A's booking_id (Assertion 1) ──────────
# B has a settlement referencing rA (Gate-2 ✓).
# Gate-1 WHERE id=rA AND user_id=kiosk.current_user_id() AND status='reserved'
# finds nothing because rA.user_id = A ≠ B → 403.
# The 403 genuinely isolates Gate-1 ownership, not a payment gap.
rc_confirm_b, confirm_b_resp = post_json(
  "#{SERVER}/kiosk/confirm_booking",
  { booking_id: booking_id_a },
  { "Authorization" => "Bearer #{token_b}" },
)
STDERR.puts "  B confirm_booking on A's rA: HTTP #{rc_confirm_b} (expected 403)"

# ── Output ONE JSON line ──────────────────────────────────────────────────────
puts JSON.generate(
  user_id_a:               user_id_a,
  user_id_b:               user_id_b,
  agent_id_a:              agent_id_a,
  agent_id_b:              agent_id_b,
  booking_id_a:            booking_id_a,
  booking_id_b:            booking_id_b,
  forged_refusal:          [rc_forge, forged_resp["code"], forged_resp["detail"]],
  b_confirm_booking_rc:    rc_confirm_b,
  b_booking_ids:           b_booking_ids,
)
