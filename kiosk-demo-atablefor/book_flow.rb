# frozen_string_literal: true

# Reference agent driver: no-human restaurant table booking end-to-end.
#
# The "book a table for two tomorrow at 8" story, with NO human and NO payment:
#   register (proof-of-possession) → query availability → book_table(party 2)
#   → my_bookings shows the confirmed booking.
#
# Usage:
#   SERVER_URL=http://127.0.0.1:3002 \
#   KIOSK_ISSUER=http://127.0.0.1:3002 \
#   bundle exec ruby book_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any failure.

require "date"
require "jwt"
require "json"
require "net/http"
require "uri"
require "openssl"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

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

# ── Step 1: generate keypair + self-register (no human; solving the PoW if
#            the provider gates registration — this demo does not) ───────────

key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode(
  { aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
  key, "RS256",
)
rc, reg = post_json(
  "#{SERVER}/kiosk/auth/register",
  { public_key: pem, signed: pop },
)
abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201

agent_id = reg.fetch("agent_id")
user_id  = reg.fetch("user_id")
token    = reg.fetch("access_token")

# ── Step 2: query availability for tomorrow, a party of 2 ────────────────────

tomorrow = (Date.today + 1).iso8601
party    = 2

rc, avail = post_json(
  "#{SERVER}/kiosk/query",
  { name: "availability", date: tomorrow, party_size: party },
  { "Authorization" => "Bearer #{token}" },
)
abort "availability failed (#{rc}): #{JSON.generate(avail)}" unless rc == 200

slots = avail.fetch("rows", [])
# The headline: a 2-top at 20:00 tomorrow ("a table for two, tomorrow at 8").
slot = slots.find { |r| r["slot_time"] == "20:00" && r["capacity"].to_i >= party } || slots.first
abort "no open slot for a party of #{party} tomorrow: #{JSON.generate(slots)}" unless slot

time = slot.fetch("slot_time")

# ── Step 3: book the table (run book_table) ──────────────────────────────────

rc, run_resp = post_json(
  "#{SERVER}/kiosk/run",
  { name: "book_table", date: tomorrow, time: time, party_size: party },
  { "Authorization" => "Bearer #{token}" },
)
abort "book_table failed (#{rc}): #{JSON.generate(run_resp)}" unless rc == 200

booking_value = run_resp.fetch("value")
booking_id    = booking_value.fetch("booking_id")
abort "book_table returned no booking_id: #{JSON.generate(booking_value)}" if booking_id.to_s.empty?

# ── Step 4: my_bookings shows the confirmed booking ──────────────────────────

rc, mine = post_json(
  "#{SERVER}/kiosk/query",
  { name: "my_bookings" },
  { "Authorization" => "Bearer #{token}" },
)
abort "my_bookings failed (#{rc}): #{JSON.generate(mine)}" unless rc == 200

booking_rows = mine.fetch("rows", [])

# ── Step 5: print ONE JSON line ──────────────────────────────────────────────

puts JSON.generate(
  http_register:  201,
  user_id:        user_id,
  agent_id:       agent_id,
  date:           tomorrow,
  time:           time,
  party_size:     party,
  booking:        booking_value,
  my_bookings:    booking_rows,
)
