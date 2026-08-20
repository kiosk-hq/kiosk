# frozen_string_literal: true

# Combette / stylish account-binding driver — two scenarios, one run:
#
#   FIRST CONTACT (claim): an assistant with a FRESH key opens the claim
#   ceremony (device_authorization → the human approves on the real verify
#   page, signed in through the Devise form → possession-proof token poll)
#   and then books an appointment as the human's account.
#
#   HUMAN-INITIATED (link): the signed-in human mints a link code, a SECOND
#   assistant redeems it at /auth/claim, sees the same account's
#   appointments — then the human unlinks the first assistant, whose login
#   is denied from that moment while the second keeps working.
#
# The human's side runs over real HTTP against the live Devise session:
# GET the sign-in form (cookie + CSRF token), POST the credentials, then
# drive the verify page with that session. No test fixtures, no in-process
# shortcuts.
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
HOLDER   = ENV.fetch("HOLDER_ID")       # seeded account holder (Alice)
EMAIL    = ENV.fetch("HOLDER_EMAIL")
PASSWORD = ENV.fetch("HOLDER_PASSWORD")

TOKEN_URL = "#{SERVER}/kiosk/oauth/token"
GRANT     = "urn:ietf:params:oauth:grant-type:device_code"

# ── the human's browser session, and the wire helpers built on it ──────────
#
# ONE mechanism, shared: lib/devise_session.rb holds the cookie jar, the CSRF
# read and the sign-in POST for every demo, and bin/check-demo-copies keeps the
# copies byte-identical. Each driver used to carry its own copy of that jar —
# five of them, free to drift, exactly the way lib/equihash_register.rb drifted
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

def jwt_claims(token)
  seg = token.split(".")[1]
  JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
end

results = {}

# ══ The human signs in through the real Devise form ═════════════════════════
SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:human_signed_in] = true
STDERR.puts "  Human signed in via /users/sign_in (Devise session cookie held)"

# ══ FIRST CONTACT: fresh key → claim ceremony → book as the account ═════════
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc, da = post_json("/kiosk/oauth/device_authorization",
                   { client_id: "stylish-binding-demo", public_key: pem })
abort "device_authorization failed (#{rc}): #{JSON.generate(da)}" unless rc == 200
results[:da_fields] = %w[device_code user_code verification_uri expires_in interval].all? { |k| da.key?(k) }
device_code = da.fetch("device_code")
user_code   = da.fetch("user_code")
interval    = da.fetch("interval", 5)
STDERR.puts "  Ceremony opened: user_code=#{user_code} → #{da["verification_uri"]}"

# Poll before approval — the assistant waits politely (authorization_pending).
req = Net::HTTP::Post.new(URI(TOKEN_URL))
req.set_form_data(grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem))
res = request(req)
pend = (JSON.parse(res.body) rescue {})
results[:pending] = [res.code.to_i, pend["error"]]

# The human opens the verify page (session-authed), sees the key fingerprint,
# approves. GET first: the consent form carries the CSRF token.
verify = get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{verify.code}" unless verify.code.to_i == 200
form = { "user_code" => user_code, "decision" => "approve" }
form["authenticity_token"] = csrf_token(verify.body) if csrf_token(verify.body)
res = post_form("/kiosk/oauth/device/verify", form)
results[:approve] = res.code.to_i
STDERR.puts "  Human approved on the verify page (#{res.code})"

# Poll again, honoring the advertised interval → the bound token.
sleep(interval + 1)
req = Net::HTTP::Post.new(URI(TOKEN_URL))
req.set_form_data(grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem))
res = request(req)
tok = (JSON.parse(res.body) rescue {})
abort "token poll failed (#{res.code}): #{JSON.generate(tok)}" unless res.code.to_i == 200
token1  = tok.fetch("access_token")
claims  = jwt_claims(token1)
agent1  = claims.fetch("agent_id")
results[:bound_user] = claims["sub"] == HOLDER
results[:agent_id_1] = agent1
STDERR.puts "  Token minted: sub=#{claims["sub"]} agent_id=#{agent1}"

# Wire verbs as the human's account: pick a salon, book, list.
rc, q = get_json("/kiosk/salons", {}, { "Authorization" => "Bearer #{token1}" })
abort "salons query failed (#{rc})" unless rc == 200
salon_id = Array(q).first.fetch("salon_id")
slot     = "#{(Date.today + 1).iso8601}T10:00:00Z"
rc, booked = post_json("/kiosk/book_appointment",
                       { salon_id: salon_id, slot: slot },
                       { "Authorization" => "Bearer #{token1}" })
results[:wire_book] = rc
appointment_id = booked["appointment_id"]
results[:appointment_id] = appointment_id
rc, mine = get_json("/kiosk/my_appointments", {}, { "Authorization" => "Bearer #{token1}" })
results[:a1_sees_booking] = rc == 200 && Array(mine).any? { |r| r["id"] == appointment_id }
STDERR.puts "  Booked appointment #{appointment_id} as the account holder"

# ══ MANAGE ASSISTANTS page: the signed-in human opens the HTML
#    governance page, sees assistant 1 listed, and sets a spending cap. ═══════
page = get_html("/kiosk/auth/assistants")
results[:manage_page] = page.code.to_i
results[:manage_lists_a1] = page.code.to_i == 200 && page.body.include?(agent1)
STDERR.puts "  Manage-assistants page (#{page.code}) lists assistant 1: #{results[:manage_lists_a1]}"

# Set a 12345-cent cap on assistant 1 (session-authed form POST).
upd = post_form("/kiosk/auth/assistants/update",
                "authenticity_token"  => csrf_token(page.body),
                "agent_id"            => agent1,
                "human_label"         => "Alice booking bot",
                "spending_cap_cents"  => "12345")
results[:manage_update] = upd.code.to_i
# The re-rendered page reflects the saved cap + label.
after = get_html("/kiosk/auth/assistants")
results[:manage_cap_shown] =
  after.code.to_i == 200 &&
  after.body.include?("cap: 12345 cents") &&
  after.body.include?("Alice booking bot")
# DB ground truth: the column now carries the cap.
STDERR.puts "  Set spending cap on assistant 1 (#{upd.code}); page shows cap: #{results[:manage_cap_shown]}"

# ══ HUMAN-INITIATED: link code → second assistant → unlink the first ════════
rc, link = post_json("/kiosk/auth/link", {}, { session: true })
results[:link_mint] = rc
key2 = OpenSSL::PKey::RSA.generate(2048)
pem2 = key2.public_key.to_pem
rc, claimed = post_json("/kiosk/auth/claim",
                        { code: link.fetch("link_code", ""), public_key: pem2,
                          signed: pop_proof(key2, pem2) })
results[:link_claim] = [rc, claimed["user_id"] == HOLDER]
agent2 = claimed["agent_id"]
token2 = claimed["access_token"].to_s
STDERR.puts "  Second assistant redeemed the link code: agent_id=#{agent2}"

# The second assistant sees the same account: the first one's booking.
rc, mine2 = get_json("/kiosk/my_appointments", {}, { "Authorization" => "Bearer #{token2}" })
results[:a2_sees_booking] = rc == 200 && Array(mine2).any? { |r| r["id"] == appointment_id }

# Unlink the first assistant (session channel) — its login dies, the
# second assistant's does not.
rc, = post_json("/kiosk/auth/unlink", { agent_id: agent1 }, { session: true })
results[:unlink] = rc
rc, = post_json("/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
results[:login_a1_after_unlink] = rc
rc, = post_json("/kiosk/auth/login", { public_key: pem2, signed: pop_proof(key2, pem2) })
results[:login_a2_still_works] = rc
STDERR.puts "  Unlinked assistant 1: its login now #{results[:login_a1_after_unlink]}, assistant 2 still #{results[:login_a2_still_works]}"

puts JSON.generate(results)
