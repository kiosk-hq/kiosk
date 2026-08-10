# frozen_string_literal: true

# Adversarial cross-tenant isolation test driver.
#
# Proves hoteling app-layer predicates enforce cross-tenant denial:
#
#   Assertion 1 — confirm_booking ownership denial (Gate-1 isolated):
#     Principal A reserves room → booking_id rA.
#     Principal B's pay call creates a settlement whose cart references rA
#     (satisfies Gate-2) then calls run confirm_booking {booking_id: rA}.
#     → Must be denied (HTTP 403). Gate-1 WHERE id=rA AND
#       user_id=kiosk.current_user_id() AND status='reserved' finds nothing
#       because rA.user_id = A ≠ B.
#     The 403 genuinely isolates Gate-1 ownership: Gate-2 (payment) is
#     satisfied by B before the attempt, so payment cannot be the blocker.
#
#   Assertion 2 — my_bookings: exclusion + positive control:
#     2a: B's query my_bookings must NOT contain rA.
#     2b (positive control): B's query must contain rB (B's own booking),
#         proving the exclusion is not vacuous.
#
#   Assertion 3 — forged user_id ignored on reserve_room:
#     B calls run reserve_room with a forged user_id arg (A's UUID).
#     → The created booking's user_id is B (server uses kiosk.current_user_id(),
#       ignores agent-supplied user_id). Verified by DB SELECT.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3004 \
#   KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby isolation_flow.rb
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

require_relative "lib/equihash_register"

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
# A uses +30..+33 days; B's forged reserve uses +60..+63 to avoid conflicts.
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
rc_props_a, props_resp_a = post_json(
  "#{SERVER}/kiosk/query",
  { name: "properties" },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A query properties failed (#{rc_props_a}): #{JSON.generate(props_resp_a)}" unless rc_props_a == 200

all_props_a = props_resp_a["rows"] || []
abort "No properties returned" if all_props_a.empty?
prop_a = all_props_a.first
prop_id_a = prop_a["property_id"]

rc_avail_a, avail_resp_a = post_json(
  "#{SERVER}/kiosk/query",
  { name: "availability",
    property_id: prop_id_a, check_in: CHECK_IN_A, check_out: CHECK_OUT_A },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A query availability failed (#{rc_avail_a}): #{JSON.generate(avail_resp_a)}" unless rc_avail_a == 200

avail_rows_a = avail_resp_a["rows"] || []
abort "No available rooms for A" if avail_rows_a.empty?
room_a           = avail_rows_a.first
room_type_id_a   = room_a["room_type_id"]
room_type_name_a = room_a["name"]
STDERR.puts "  A will reserve #{room_type_name_a} at property #{prop_id_a}"

# ── Step 4: A reserves room → booking_id rA ──────────────────────────────────
rc_rsv_a, rsv_a_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "reserve_room",
    property_id: prop_id_a, room_type_id: room_type_id_a,
    check_in: CHECK_IN_A, check_out: CHECK_OUT_A },
  { "Authorization" => "Bearer #{token_a}" },
)
abort "A reserve_room failed (#{rc_rsv_a}): #{JSON.generate(rsv_a_resp)}" unless rc_rsv_a == 200

booking_id_a = rsv_a_resp.dig("value", "booking_id")
total_cents_a = rsv_a_resp.dig("value", "total_cents").to_i
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
STDERR.puts "  B paid for rA: settlement_id=#{pay_b_resp.dig("value", "settlement_id")} — Gate-2 now passes for B"

# ── Step 6: B calls reserve_room with forged user_id arg (Assertion 3) ───────
# B supplies user_id: user_id_a adversarially. The server ignores it —
# the INSERT uses kiosk.current_user_id() (B's UUID). Verified via DB SELECT.
# Use a different date range (B_dates) to avoid A's booking blocking availability.
#
# First find an available room for B's date range.
rc_props_b, props_resp_b = post_json(
  "#{SERVER}/kiosk/query",
  { name: "properties" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B query properties failed (#{rc_props_b})" unless rc_props_b == 200

all_props_b = props_resp_b["rows"] || []
# Find a property with availability for B's date range (any property).
prop_b = nil
room_b = nil
all_props_b.each do |p|
  rc_av, av_r = post_json(
    "#{SERVER}/kiosk/query",
    { name: "availability",
      property_id: p["property_id"], check_in: CHECK_IN_B, check_out: CHECK_OUT_B },
    { "Authorization" => "Bearer #{token_b}" },
  )
  next unless rc_av == 200
  rows = av_r["rows"] || []
  if rows.any?
    prop_b = p
    room_b = rows.first
    break
  end
end
abort "B: no room available for #{CHECK_IN_B}..#{CHECK_OUT_B}" unless prop_b

rc_forge, forged_resp = post_json(
  "#{SERVER}/kiosk/run",
  {
    name:         "reserve_room",
    property_id:  prop_b["property_id"],
    room_type_id: room_b["room_type_id"],
    check_in:     CHECK_IN_B,
    check_out:    CHECK_OUT_B,
    user_id:      user_id_a,  # adversarial: B supplies A's user_id
  },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B forged reserve failed (#{rc_forge}): #{JSON.generate(forged_resp)}" unless rc_forge == 200

booking_id_b_forged = forged_resp.dig("value", "booking_id")
abort "B's forged booking_id missing: #{JSON.generate(forged_resp)}" unless booking_id_b_forged
STDERR.puts "  B forged reserve: booking_id=#{booking_id_b_forged}"

# ── Step 7: B queries my_bookings (Assertion 2) ───────────────────────────────
# B now has booking_id_b_forged as its own row (Step 6). Two assertions:
#   2a exclusion:        b_booking_ids must NOT contain rA.
#   2b positive control: b_booking_ids MUST contain rB_forged, proving
#     the exclusion is non-vacuous (the query actually returns B's own rows).
rc_b_bookings, b_bookings_resp = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_bookings" },
  { "Authorization" => "Bearer #{token_b}" },
)
abort "B my_bookings failed (#{rc_b_bookings}): #{JSON.generate(b_bookings_resp)}" unless rc_b_bookings == 200

b_booking_ids = (b_bookings_resp["rows"] || []).map { |r| r["booking_id"] }
STDERR.puts "  B my_bookings: #{b_booking_ids.inspect}"

# ── Step 8: B calls confirm_booking on A's booking_id (Assertion 1) ──────────
# B has a settlement referencing rA (Gate-2 ✓).
# Gate-1 WHERE id=rA AND user_id=kiosk.current_user_id() AND status='reserved'
# finds nothing because rA.user_id = A ≠ B → 403.
# The 403 genuinely isolates Gate-1 ownership, not a payment gap.
rc_confirm_b, confirm_b_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "confirm_booking", booking_id: booking_id_a },
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
  booking_id_b_forged:     booking_id_b_forged,
  b_confirm_booking_rc:    rc_confirm_b,
  b_booking_ids:           b_booking_ids,
)
