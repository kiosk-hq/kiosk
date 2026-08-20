# frozen_string_literal: true

# philslist account-binding driver — the binding ceremony + the MULTI-ACCOUNT
# household proof, two scenarios in one run:
#
#   FIRST CONTACT (claim): an assistant with a FRESH key opens the claim
#   ceremony (device_authorization → the human approves on the real verify page,
#   signed in through the Devise form → possession-proof token poll) and then
#   POSTS A LISTING as the human's account.
#
#   HOUSEHOLD (link + multi-account): the signed-in human mints a link code, a
#   SECOND assistant redeems it at /auth/claim, sees the SAME account's listings
#   (assistant 1's listing) and EDITS it — a household with separate assistants,
#   no new framework surface. The human then unlinks the first assistant, whose
#   login is denied from that moment while the second keeps working.
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

# ══ FIRST CONTACT: fresh key → claim ceremony → post as the account ═════════
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc, da = post_json("/kiosk/oauth/device_authorization",
                   { client_id: "philslist-binding-demo", public_key: pem })
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

# The human opens the verify page (session-authed), approves. GET first: the
# consent form carries the CSRF token.
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

# Wire verbs as the human's account: post a listing, list.
rc, posted = post_json("/kiosk/post_listing",
                       { category_slug: "furniture",
                         title: "Household desk", body: "Posted by assistant 1", price_text: "€150" },
                       { "Authorization" => "Bearer #{token1}" })
results[:wire_post] = rc
listing_id = posted["listing_id"]
results[:listing_id] = listing_id
rc, mine = get_json("/kiosk/my_listings", {}, { "Authorization" => "Bearer #{token1}" })
results[:a1_sees_listing] = rc == 200 && Array(mine).any? { |r| r["listing_id"] == listing_id }
STDERR.puts "  Posted listing #{listing_id} as the account holder"

# ══ MANAGE ASSISTANTS page: the signed-in human sees assistant 1 listed. ═════
page = get_html("/kiosk/auth/assistants")
results[:manage_page] = page.code.to_i
results[:manage_lists_a1] = page.code.to_i == 200 && page.body.include?(agent1)
STDERR.puts "  Manage-assistants page (#{page.code}) lists assistant 1: #{results[:manage_lists_a1]}"

# ══ HOUSEHOLD: link code → SECOND assistant → sees + edits the same account ══
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
results[:agent_id_2] = agent2
STDERR.puts "  Second assistant redeemed the link code: agent_id=#{agent2}"

# The second assistant sees the SAME account: assistant 1's listing.
rc, mine2 = get_json("/kiosk/my_listings", {}, { "Authorization" => "Bearer #{token2}" })
results[:a2_sees_listing] = rc == 200 && Array(mine2).any? { |r| r["listing_id"] == listing_id }

# And the second assistant can EDIT the household listing (multi-account write).
rc, = post_json("/kiosk/edit_listing",
                { listing_id: listing_id, price_text: "€140" },
                { "Authorization" => "Bearer #{token2}" })
results[:a2_edit] = rc
STDERR.puts "  Second assistant edited the household listing → #{rc}"

# Unlink the first assistant (session channel) — its login dies, the second's does not.
rc, = post_json("/kiosk/auth/unlink", { agent_id: agent1 }, { session: true })
results[:unlink] = rc
rc, = post_json("/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
results[:login_a1_after_unlink] = rc
rc, = post_json("/kiosk/auth/login", { public_key: pem2, signed: pop_proof(key2, pem2) })
results[:login_a2_still_works] = rc
STDERR.puts "  Unlinked assistant 1: its login now #{results[:login_a1_after_unlink]}, assistant 2 still #{results[:login_a2_still_works]}"

puts JSON.generate(results)
