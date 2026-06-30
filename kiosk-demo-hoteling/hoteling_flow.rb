# frozen_string_literal: true
#
# Agent-side driver: no-human hotel booking end-to-end.
# Flow: register → query properties → query availability → run reserve_room → pay → run confirm_booking
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3004 KIOSK_ISSUER=http://127.0.0.1:3004 bundle exec ruby hoteling_flow.rb
#
# Optional env:
#   SKIP_PAY=1  — skip pay (confirm_booking should return 403)
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected failures.

require "date"
require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
SKIP_PAY = ENV.key?("SKIP_PAY")

def post_json(url, body, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Step 1: register (no PoW for hoteling) ──────────────────────────────

key = OpenSSL::PKey::RSA.generate(2048)

rc_reg, reg = post_json(
  "#{SERVER}/kiosk/agents/register",
  { name: "hermes-hoteling", public_key: key.public_key.to_pem, role: "customer" },
)
abort "register failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

STDERR.puts "  Registered: user_id=#{user_id}"

# ── Step 2: query properties ─────────────────────────────────────────────

rc_props, props_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "properties" } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query properties failed (#{rc_props}): #{JSON.generate(props_resp)}" unless rc_props == 200

props = props_resp.fetch("rows")
abort "properties returned empty rows" if props.empty?
target_property = props.first
property_id     = target_property.fetch("id")
STDERR.puts "  Properties: #{props.size} found, using id=#{property_id} (#{target_property["name"]})"

# ── Step 3: query availability ────────────────────────────────────────────

check_in  = (Date.today + 30).to_s
check_out = (Date.today + 33).to_s

rc_avail, avail_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "query", body: { name: "availability", property_id: property_id, check_in: check_in, check_out: check_out } },
  { "Authorization" => "Bearer #{token}" },
)
abort "query availability failed (#{rc_avail}): #{JSON.generate(avail_resp)}" unless rc_avail == 200

avail_rows = avail_resp.fetch("rows")
abort "availability returned empty rows" if avail_rows.empty?
target_room = avail_rows.first
room_type_id   = target_room.fetch("id")
room_type_name = target_room.fetch("name")
nightly_price  = target_room.fetch("nightly_price_cents")
STDERR.puts "  Availability: #{avail_rows.size} room type(s) available, using id=#{room_type_id} (#{room_type_name}, #{nightly_price}c/night)"

# ── Step 4: reserve_room ──────────────────────────────────────────────────

rc_rsv, rsv_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "reserve_room", property_id: property_id, room_type_id: room_type_id,
                            check_in: check_in, check_out: check_out } },
  { "Authorization" => "Bearer #{token}" },
)
abort "reserve_room failed (#{rc_rsv}): #{JSON.generate(rsv_resp)}" unless rc_rsv == 200

rsv_value   = rsv_resp.fetch("value")
booking_id  = rsv_value.fetch("booking_id")
total_cents = rsv_value.fetch("total_cents")
STDERR.puts "  Reserved: booking_id=#{booking_id} total=#{total_cents}c"

# Calculate nights for the cart
nights = (Date.parse(check_out) - Date.parse(check_in)).to_i

# ── Step 5: pay ───────────────────────────────────────────────────────────

rc_pay   = nil
pay_resp = {}

unless SKIP_PAY
  now        = Time.now.to_i
  intent_id  = SecureRandom.uuid
  cart_id    = SecureRandom.uuid
  payment_id = SecureRandom.uuid

  intent_payload = {
    id:               intent_id,
    user_id:          user_id,
    agent_id:         agent_id,
    iss:              ISSUER,
    scope:            "lodging",
    cap_amount_cents: total_cents + 100,
    currency:         "eur",
    exp:              now + 600,
    iat:              now,
  }

  cart_payload = {
    id:                 cart_id,
    intent_mandate_id:  intent_id,
    user_id:            user_id,
    agent_id:           agent_id,
    iss:                ISSUER,
    line_items:         [{ sku: room_type_name, qty: nights, booking_id: booking_id }],
    total_amount_cents: total_cents,
    currency:           "eur",
    exp:                now + 600,
    iat:                now,
  }

  payment_payload = {
    id:              payment_id,
    cart_mandate_id: cart_id,
    user_id:         user_id,
    agent_id:        agent_id,
    iss:             ISSUER,
    payment_method:  "pm_demo",
    amount_cents:    total_cents,
    currency:        "eur",
    exp:             now + 600,
    iat:             now,
  }

  intent_jws  = JWT.encode(intent_payload,  key, "RS256")
  cart_jws    = JWT.encode(cart_payload,    key, "RS256")
  payment_jws = JWT.encode(payment_payload, key, "RS256")

  rc_pay, pay_resp = post_json(
    "#{SERVER}/kiosk/exec",
    { command: "pay",
      body: { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
               payment_mandate_jws: payment_jws } },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
  STDERR.puts "  Payment settled: settlement_id=#{pay_resp.dig("value", "settlement_id")}"
end

# ── Step 6: confirm_booking ───────────────────────────────────────────────

rc_confirm, confirm_resp = post_json(
  "#{SERVER}/kiosk/exec",
  { command: "run", body: { name: "confirm_booking", booking_id: booking_id } },
  { "Authorization" => "Bearer #{token}" },
)

# ── Step 7: print ONE JSON line ───────────────────────────────────────────

puts JSON.generate(
  http_register:        rc_reg,
  http_properties:      rc_props,
  http_availability:    rc_avail,
  http_reserve_room:    rc_rsv,
  http_pay:             rc_pay,
  http_confirm_booking: rc_confirm,
  user_id:              user_id,
  agent_id:             agent_id,
  booking_id:           booking_id,
  total_cents:          total_cents,
  confirm_status:       confirm_resp.dig("value", "status"),
  confirmation_code:    confirm_resp.dig("value", "confirmation_code"),
)
