# frozen_string_literal: true
#
# Agent-side driver: no-human hotel booking end-to-end.
# Flow: register → properties → availability → reserve_room → pay → confirm_booking
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING; an action is `POST <endpoint>/<action-name>` with its
# arguments as the JSON BODY. There is no `name` field and no /query or /run
# endpoint. A success body IS the result — a bare array from a non-paginating
# query, the action's own object from an action — and an error is an RFC 9457
# problem document whose branch point is the TOP-LEVEL `code`.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3003 KIOSK_ISSUER=http://127.0.0.1:3003 bundle exec ruby script/hoteling_flow.rb
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

# ── Step 1: register (register PoW solved transparently). The SAME private key
#            is returned so the payment mandates below can be signed with it. ──

require_relative "equihash_register"
key, reg, rc_register = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: method(:get_json), post_json: method(:post_json),
)

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

STDERR.puts "  Registered: user_id=#{user_id}"

# ── Step 2: query properties ─────────────────────────────────────────────

rc_props, props_resp = query_json(
  "properties", {},
  { "Authorization" => "Bearer #{token}" },
)
abort "query properties failed (#{rc_props}): #{JSON.generate(props_resp)}" unless rc_props == 200

# A non-paginating query answers a BARE ARRAY — the rows, with nothing around
# them (0.4 retired the `{rows: …}` envelope).
props = Array(props_resp)
abort "properties returned empty rows" if props.empty?
target_property = props.first
property_id     = target_property.fetch("property_id")
STDERR.puts "  Properties: #{props.size} found, using property_id=#{property_id} (#{target_property["name"]})"

# ── Step 3: query availability ────────────────────────────────────────────

check_in  = (Date.today + 30).to_s
check_out = (Date.today + 33).to_s

rc_avail, avail_resp = query_json(
  "availability",
  { property_id: property_id, check_in: check_in, check_out: check_out },
  { "Authorization" => "Bearer #{token}" },
)
abort "query availability failed (#{rc_avail}): #{JSON.generate(avail_resp)}" unless rc_avail == 200

avail_rows = Array(avail_resp)
abort "availability returned empty rows" if avail_rows.empty?
target_room = avail_rows.first
room_type_id   = target_room.fetch("room_type_id")
room_type_name = target_room.fetch("name")
nightly_price  = target_room.fetch("nightly_price_cents")
# Human-facing nightly rate in EUR (€120.00/night), never raw cents.
nightly_price_eur = format("€%.2f", nightly_price.to_i / 100.0)
STDERR.puts "  Availability: #{avail_rows.size} room type(s) available, using room_type_id=#{room_type_id} (#{room_type_name}, #{nightly_price_eur}/night)"

# ── Step 4: reserve_room ──────────────────────────────────────────────────

rc_rsv, rsv_resp = post_json(
  "#{SERVER}/kiosk/reserve_room",
  { property_id: property_id, room_type_id: room_type_id,
    check_in: check_in, check_out: check_out },
  { "Authorization" => "Bearer #{token}" },
)
abort "reserve_room failed (#{rc_rsv}): #{JSON.generate(rsv_resp)}" unless rc_rsv == 200

# An action's success body IS its own object — the `{value: …}` wrapper is gone.
booking_id  = rsv_resp.fetch("booking_id")
total_cents = rsv_resp.fetch("total_cents")
# Human-facing total in EUR (€120.00), never raw cents; the wire stays cents.
STDERR.puts "  Reserved: booking_id=#{booking_id} total=#{format("€%.2f", total_cents.to_i / 100.0)}"

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
    line_items:         [{ sku: room_type_name, qty: nights, price_cents: nightly_price, booking_id: booking_id }],
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
    "#{SERVER}/kiosk/pay",
    { intent_mandate_jws: intent_jws, cart_mandate_jws: cart_jws,
      payment_mandate_jws: payment_jws },
    { "Authorization" => "Bearer #{token}" },
  )
  abort "pay failed (#{rc_pay}): #{JSON.generate(pay_resp)}" unless rc_pay == 200
  STDERR.puts "  Payment settled: settlement_id=#{pay_resp["settlement_id"]}"
end

# ── Step 6: confirm_booking ───────────────────────────────────────────────

rc_confirm, confirm_resp = post_json(
  "#{SERVER}/kiosk/confirm_booking",
  { booking_id: booking_id },
  { "Authorization" => "Bearer #{token}" },
)

# ── Step 6b: read the confirmation code back (K-698) ──────────────────────
# The code confirm_booking hands over is only a booking reference if the hotel
# KEPT it. It used to be a SecureRandom.uuid minted for the response against a
# table with no such column, so a guest quoting it at the desk could not be
# matched. Re-query my_bookings for this booking and report the stored code, so
# demo:book can assert the two are the same string.
rc_mine, mine_resp = query_json(
  "my_bookings", {},
  { "Authorization" => "Bearer #{token}" },
)
stored_row = Array(mine_resp).find { |r| r["booking_id"] == booking_id }

# ── Step 7: print ONE JSON line ───────────────────────────────────────────

puts JSON.generate(
  http_register:        rc_register,
  http_properties:      rc_props,
  http_availability:    rc_avail,
  http_reserve_room:    rc_rsv,
  http_pay:             rc_pay,
  http_confirm_booking: rc_confirm,
  user_id:              user_id,
  agent_id:             agent_id,
  booking_id:           booking_id,
  total_cents:          total_cents,
  # Only on a 200, because an RFC 9457 problem document ALSO carries a top-level
  # `status` — the HTTP one. Reading it unconditionally would report the
  # SKIP_PAY refusal as `confirm_status: 403`, a booking status that does not
  # exist, where the honest answer is "the booking was never confirmed".
  confirm_status:       (confirm_resp["status"] if rc_confirm == 200),
  confirmation_code:    confirm_resp["confirmation_code"],
  http_my_bookings:     rc_mine,
  stored_confirmation_code: stored_row && stored_row["confirmation_code"],
)
