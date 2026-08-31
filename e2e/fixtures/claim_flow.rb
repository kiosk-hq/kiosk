# frozen_string_literal: true

# Account-binding proof: the full claim ceremony (fresh key → human approval
# on the verify page → possession-proof token poll), a wire call as the bound
# assistant account, the human-initiated link-code redeem, and unlink.
# Prints a JSON result line on stdout; the shell asserts each field.
require "jwt"; require "json"; require "net/http"; require "uri"; require "openssl"; require "securerandom"; require "base64"

# The human half of this ceremony is a REAL browser session (T-066): there is
# no stub user-IdP left to hand this driver a `user:u-<uuid>` bearer. The
# cookie-jar-and-CSRF helper is the demos' single copy — reached here rather
# than duplicated into e2e/fixtures, because an eighth copy of a mechanism is
# how the seventh one drifts.
require_relative "../../kiosk-demo-stylish/script/devise_session"

SERVER   = ENV.fetch("SERVER_URL")
ISSUER   = ENV.fetch("KIOSK_ISSUER")
HUMAN    = ENV.fetch("HUMAN_USER_ID")     # seeded account holder (alice)
EMAIL    = ENV.fetch("HUMAN_EMAIL")
PASSWORD = ENV.fetch("HUMAN_PASSWORD")

# Alice's browser, signed in once and held for every human-side call below.
HUMAN_SESSION = DeviseSession.new(SERVER)

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

def post_form(url, form, headers = {})
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, headers)
  req.set_form_data(form)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# Fresh possession proof (same challenge-response JWS as register/login).
def pop_proof(key, pem)
  rc, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed: #{rc} #{ch}" unless rc == 200
  JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
end

TOKEN_URL = "#{SERVER}/kiosk/oauth/token"
GRANT     = "urn:ietf:params:oauth:grant-type:device_code"
results   = {}

# ── claim ceremony: the agent brings a FRESH key ──
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem

# THE OPENING REQUEST MAY NOT NAME A ROLE (K-072, covered here by K-1129).
#
# This request is UNAUTHENTICATED — no Cookie, no Authorization — so anything it
# carries is an assertion by a stranger. The engine used to read `role` (or its
# OAuth spelling `scope`) off it and bake the value into the JWT the poll
# returns, with membership of `config.roles` as the only filter; the role now
# comes from the approving human and the parameter is REFUSED rather than
# ignored.
#
# THE DECLARED VALUE IS THE ONE THAT MATTERS. An UNDECLARED role (`owner` here —
# this origin declares only `customer`) was refused by the vulnerable code too,
# so a probe using only that cannot fail. `role=customer` is the probe with
# teeth: it answered 200 before the fix, on this very fixture. Both transports
# are probed because the controller reads `params[:role]`, which Rails fills
# from a form body and a JSON body alike — a guard on one would not be a guard.
role_probes = [%w[role customer], %w[scope customer], %w[role owner]].map do |param, value|
  code, body = post_form("#{SERVER}/kiosk/oauth/device_authorization",
                         { "client_id" => "e2e-claim-flow", "public_key" => pem, param => value })
  "#{param}=#{value}:#{code}:#{body["error"]}"
end
code, body = post_json("#{SERVER}/kiosk/oauth/device_authorization",
                       { client_id: "e2e-claim-flow", public_key: pem, role: "customer" })
role_probes << "json-role=customer:#{code}:#{body["error"]}"
results[:role_refused] = role_probes

rc, da = post_json("#{SERVER}/kiosk/oauth/device_authorization", { client_id: "e2e-claim-flow", public_key: pem })
abort "device_authorization failed: #{rc} #{da}" unless rc == 200
device_code = da.fetch("device_code")
user_code   = da.fetch("user_code")
results[:da_fields] = %w[device_code user_code verification_uri expires_in interval].all? { |k| da.key?(k) }

# Poll with a valid proof before approval → authorization_pending.
rc, tok = post_form(TOKEN_URL, { grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem) })
results[:pending] = [rc, tok["error"]]

# The human signs in through the REAL Devise form, then approves on the verify
# page: GET first (the page + its CSRF token), then POST approve over the same
# session. A failed sign-in raises, so `signed_in` is never a wish.
HUMAN_SESSION.sign_in!(email: EMAIL, password: PASSWORD)
results[:signed_in] = true

show = HUMAN_SESSION.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
abort "verify page: #{show.code}" unless show.code.to_i == 200
form = { user_code: user_code, decision: "approve" }
if (csrf = HUMAN_SESSION.csrf_token(show.body))
  form[:authenticity_token] = csrf
end
results[:approve] = HUMAN_SESSION.post_form("/kiosk/oauth/device/verify", form).code.to_i

# The BIND-POP gate, at the moment it matters: an APPROVED row polled
# WITHOUT the possession proof is denied (invalid_client) and stays
# approved — nothing binds. (Pacing first: the registry counts every poll.)
sleep(da.fetch("interval", 5) + 1)
rc, tok = post_form(TOKEN_URL, { grant_type: GRANT, device_code: device_code })
results[:no_pop] = [rc, tok["error"]]

# Polling faster than the advertised `interval` answers slow_down
# (RFC 8628 §3.5) — assert it once, then honor the pace.
rc, tok = post_form(TOKEN_URL, { grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem) })
results[:slow_down] = [rc, tok["error"]]
sleep(da.fetch("interval", 5) + 1)
rc, tok = post_form(TOKEN_URL, { grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem) })
abort "token poll failed: #{rc} #{tok}" unless rc == 200
token = tok.fetch("access_token")
# OAuth-pure response: identity rides inside the kiosk JWT claims.
seg = token.split(".")[1]
claims = JSON.parse(Base64.urlsafe_decode64(seg + "=" * ((4 - seg.length % 4) % 4)))
results[:bound_user] = claims["sub"] == HUMAN
# The role the binding carries is the APPROVER's, read from this origin's
# identity system when Alice approved — never anything the caller sent. Alice's
# User model defines no `#kiosk_role`, so kiosk-user-idp-devise answers the
# first declared role; that this origin declares exactly one is why the
# assertion is an equality rather than a distinction (see the note beside
# `c.roles` in fixtures/initializer_kiosk.rb).
results[:token_role] = claims["role"]
agent_id = claims.fetch("agent_id")

# Wire verb as the bound assistant account — a query is a GET at its own path.
rc, q = get_json("#{SERVER}/kiosk/my_appointments", { "Authorization" => "Bearer #{token}" })
# 0.4: the answer IS the rows (T-068 slice 2), so "the wire served it" is "a
# list came back", not "ok was true".
results[:wire_as_bound] = [rc, q.is_a?(Array)]

# kiosk-pop login stays the refresh path for the bound key.
rc, = post_json("#{SERVER}/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
results[:login_bound] = rc

# ── link flow: the human mints a code, a second assistant redeems it ──
key2 = OpenSSL::PKey::RSA.generate(2048)
pem2 = key2.public_key.to_pem
rc, link = HUMAN_SESSION.post_json("/kiosk/auth/link", {}, { session: true })
results[:link_mint] = rc
rc, claim = post_json("#{SERVER}/kiosk/auth/claim",
                      { code: link.fetch("link_code", ""), public_key: pem2, signed: pop_proof(key2, pem2) })
results[:link_claim] = [rc, claim["user_id"] == HUMAN]

# ── unlink the first assistant: registration-layer revocation ──
#
# Spec §6.3/§15.4 promise BOTH halves — "the key's tokens stop verifying AND
# /auth/login answers 404" — and this driver used to assert only the second,
# which is how the same-second aperture in the watermark survived unnoticed
# (K-835). Re-login aligned to a wall-clock second boundary so the fresh token's
# `iat` lands in the SAME second as the unlink, then assert the refusal.
proof = pop_proof(key, pem)
sleep(1.0 - (Time.now.to_f % 1.0) + 0.02)
rc, fresh = post_json("#{SERVER}/kiosk/auth/login", { public_key: pem, signed: proof })
fresh_token = rc == 200 ? fresh.fetch("access_token") : token
rc, = HUMAN_SESSION.post_json("/kiosk/auth/unlink", { agent_id: agent_id }, { session: true })
results[:unlink] = rc

rc, = get_json("#{SERVER}/kiosk/my_appointments", { "Authorization" => "Bearer #{token}" })
results[:held_token_after_unlink] = rc
rc, = get_json("#{SERVER}/kiosk/my_appointments", { "Authorization" => "Bearer #{fresh_token}" })
results[:same_second_token_after_unlink] = rc

# T-158: the CODE, not only the status. A key the origin no longer knows is
# spec §9.1 rule 2 -- an argument ADDRESSING something absent -- so it is
# `not_found` and specifically NOT `verb_not_found`, which is the other 404 in
# the vocabulary and means an unregistered verb NAME. This is the only place in
# the harness that reaches an addressed-thing-absent 404 through a real
# possession proof, so it is where the second of the three T-158 codes is
# exercised on a booted origin.
rc, login_body = post_json("#{SERVER}/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
results[:login_after_unlink]      = rc
results[:login_after_unlink_code] = login_body.is_a?(Hash) ? login_body["code"] : nil
results[:login_after_unlink_type] = login_body.is_a?(Hash) ? login_body["type"] : nil

puts JSON.generate(results)
