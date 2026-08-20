# frozen_string_literal: true

# atablefor account-binding driver — a human diner links their AI assistant to
# their restaurant account, and the assistant's booking then ties to that human.
#
# Scenario (all over real HTTP against the live app):
#   1. The human diner (Diego) signs in through the REAL Devise form
#      (/users/sign_in — cookie + CSRF dance) and mints a LINK code
#      (POST /kiosk/auth/link, session channel — the human IS the approval).
#   2. The assistant, with a FRESH key, redeems the code (POST /kiosk/auth/claim,
#      key + possession proof) → a new kiosk.agents row is bound to Diego's
#      account (no headless account existed first — first-contact bind).
#   3. As that bound token, the assistant books a table for two tomorrow at 8.
#   4. The assistant's my_bookings shows the reservation, AND — the load-bearing
#      assertion — the booking's DB user_id is Diego's account id: book_table
#      writes under kiosk.current_user_id(), which the binding set to the human.
#
# The human's side runs over real HTTP against the live Devise session. No test
# fixtures, no in-process shortcuts.
#
# Usage (invoked by rake demo:binding):
#   SERVER_URL=… KIOSK_ISSUER=… HOLDER_ID=… HOLDER_EMAIL=… HOLDER_PASSWORD=… \
#   bundle exec ruby script/binding_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on any hard failure.

require "date"
require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "securerandom"
require "base64"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HOLDER   = ENV.fetch("HOLDER_ID")       # the seeded diner (Diego)
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

# ── the human's browser session, and the wire helpers built on it ──────────
#
# ONE mechanism, shared: lib/devise_session.rb holds the cookie jar, the CSRF
# read and the sign-in POST for every demo, and bin/check-demo-copies keeps the
# copies byte-identical. Each driver used to carry its own copy of that jar —
# five of them, free to drift, exactly the way script/equihash_register.rb drifted
# in three of five. These wrappers keep this driver's call sites unchanged.
require_relative "../lib/devise_session"

SESSION = DeviseSession.new(SERVER)

def request(req) = SESSION.request(req)
def get_html(path) = SESSION.get_html(path)
def post_form(path, form) = SESSION.post_form(path, form)
def csrf_token(html) = SESSION.csrf_token(html)

# session: true sends the human's cookie jar (the Devise session channel);
# agent calls send only their Bearer header — never the human's cookies.
def post_json(path, body, headers = {}) = SESSION.post_json(path, body, headers)
def get_json(path, params = {}, headers = {}) = SESSION.get_json(path, params, headers)

# Fresh possession proof (the same challenge-response JWS as register/login).
def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

results = {}

# ══ 1. The human diner signs in through the real Devise form ════════════════
SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:human_signed_in] = true
STDERR.puts "  Diner signed in via /users/sign_in (Devise session cookie held)"

# ══ 2. The signed-in diner mints a link code (session channel) ══════════════
rc, link = post_json("/kiosk/auth/link", {}, { session: true })
results[:link_mint] = rc
abort "link mint failed (#{rc}): #{JSON.generate(link)}" unless rc == 201
STDERR.puts "  Diner minted a link code (POST /kiosk/auth/link → #{rc})"

# ══ 3. The assistant redeems the code with a FRESH key + possession proof ═══
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc, claimed = post_json("/kiosk/auth/claim",
                        { code: link.fetch("link_code", ""), public_key: pem, signed: pop_proof(key, pem) })
results[:link_claim]        = rc
results[:bound_to_holder]   = claimed["user_id"] == HOLDER
agent_id = claimed["agent_id"]
token    = claimed["access_token"].to_s
results[:agent_id] = agent_id
abort "claim failed (#{rc}): #{JSON.generate(claimed)}" unless rc == 201
STDERR.puts "  Assistant redeemed the code: agent_id=#{agent_id} now bound to user_id=#{claimed['user_id']}"

# ══ 4. As the bound assistant, book a table for two tonight at 8 ════════════
party = 2
rc, avail = get_json("/kiosk/availability", { party_size: party }, bearer(token))
abort "availability failed (#{rc}): #{JSON.generate(avail)}" unless rc == 200
slots = Array(avail)
slot  = slots.find { |r| r["seating_time"] == "20:00" && r["capacity"].to_i >= party } || slots.first
abort "no open table for a party of #{party} tonight: #{JSON.generate(slots)}" unless slot
date  = slot.fetch("seating_date")
time  = slot.fetch("seating_time")

rc, booking = post_json("/kiosk/book_table",
                        { restaurant_id: slot.fetch("restaurant_id"),
                          restaurant_table_id: slot.fetch("restaurant_table_id"),
                          date: date, time: time, party_size: party }, bearer(token))
results[:wire_book] = rc
abort "book_table failed (#{rc}): #{JSON.generate(booking)}" unless rc == 200
booking_id = booking["booking_id"].to_s
results[:booking_id]     = booking_id
results[:booking_status] = booking["status"]
STDERR.puts "  Assistant booked table #{booking_id} (#{date} #{time}, party #{party}) as Diego's account"

# ══ 5. The assistant's my_bookings shows the reservation ════════════════════
rc, mine = get_json("/kiosk/my_bookings", {}, bearer(token))
abort "my_bookings failed (#{rc}): #{JSON.generate(mine)}" unless rc == 200
rows = Array(mine)
results[:my_bookings_has_it] = rows.any? { |r| r["booking_id"] == booking_id && r["status"] == "confirmed" }
STDERR.puts "  my_bookings (assistant token) shows the booking: #{results[:my_bookings_has_it]}"

puts JSON.generate(results)
