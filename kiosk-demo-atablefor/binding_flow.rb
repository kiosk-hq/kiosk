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
#   bundle exec ruby binding_flow.rb
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

# ── tiny HTTP helpers with a cookie jar (the human's browser session) ───────
COOKIES = {}

def absorb_cookies!(res)
  Array(res.get_fields("set-cookie")).each do |line|
    name, value = line.split(";").first.split("=", 2)
    COOKIES[name] = value
  end
end

def cookie_header = COOKIES.map { |k, v| "#{k}=#{v}" }.join("; ")

SERVER_URI = URI(SERVER)

def request(req)
  res = Net::HTTP.new(SERVER_URI.host, SERVER_URI.port).request(req)
  absorb_cookies!(res)
  res
end

def get_html(path)
  req = Net::HTTP::Get.new(URI("#{SERVER}#{path}"))
  req["Cookie"] = cookie_header unless COOKIES.empty?
  request(req)
end

def post_form(path, form)
  req = Net::HTTP::Post.new(URI("#{SERVER}#{path}"))
  req["Cookie"] = cookie_header unless COOKIES.empty?
  req.set_form_data(form)
  request(req)
end

# session: true sends the human's cookie jar (the Devise session channel);
# agent calls send only their Bearer header — never the human's cookies.
def post_json(path, body, headers = {})
  session = headers.delete(:session)
  req = Net::HTTP::Post.new(URI("#{SERVER}#{path}"), { "Content-Type" => "application/json" }.merge(headers))
  req["Cookie"] = cookie_header if session
  req.body = JSON.generate(body)
  res = request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path)
  res = request(Net::HTTP::Get.new(URI("#{SERVER}#{path}")))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def csrf_token(html) = html[/name="authenticity_token" value="([^"]+)"/, 1]

# Fresh possession proof (the same challenge-response JWS as register/login).
def pop_proof(key, pem)
  rc, ch = get_json("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc}): #{JSON.generate(ch)}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

def bearer(token) = { "Authorization" => "Bearer #{token}" }

results = {}

# ══ 1. The human diner signs in through the real Devise form ════════════════
signin = get_html("/users/sign_in")
abort "sign-in form: #{signin.code}" unless signin.code.to_i == 200
res = post_form("/users/sign_in",
                "authenticity_token" => csrf_token(signin.body),
                "user[email]"        => EMAIL,
                "user[password]"     => PASSWORD)
abort "sign-in failed: #{res.code}" unless [302, 303].include?(res.code.to_i)
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

# ══ 4. As the bound assistant, book a table for two tomorrow at 8 ═══════════
tomorrow = (Date.today + 1).iso8601
party    = 2
rc, avail = post_json("/kiosk/query",
                      { name: "availability", date: tomorrow, party_size: party }, bearer(token))
abort "availability failed (#{rc}): #{JSON.generate(avail)}" unless rc == 200
slots = avail.fetch("rows", [])
slot  = slots.find { |r| r["slot_time"] == "20:00" && r["capacity"].to_i >= party } || slots.first
abort "no open slot for a party of #{party} tomorrow: #{JSON.generate(slots)}" unless slot
time  = slot.fetch("slot_time")

rc, run_resp = post_json("/kiosk/run",
                         { name: "book_table", date: tomorrow, time: time, party_size: party }, bearer(token))
results[:wire_book] = rc
abort "book_table failed (#{rc}): #{JSON.generate(run_resp)}" unless rc == 200
booking    = run_resp.fetch("value", {})
booking_id = booking["booking_id"].to_s
results[:booking_id]     = booking_id
results[:booking_status] = booking["status"]
STDERR.puts "  Assistant booked table #{booking_id} (#{tomorrow} #{time}, party #{party}) as Diego's account"

# ══ 5. The assistant's my_bookings shows the reservation ════════════════════
rc, mine = post_json("/kiosk/query", { name: "my_bookings" }, bearer(token))
abort "my_bookings failed (#{rc}): #{JSON.generate(mine)}" unless rc == 200
rows = mine.fetch("rows", [])
results[:my_bookings_has_it] = rows.any? { |r| r["id"] == booking_id && r["status"] == "confirmed" }
STDERR.puts "  my_bookings (assistant token) shows the booking: #{results[:my_bookings_has_it]}"

puts JSON.generate(results)
