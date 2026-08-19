# frozen_string_literal: true

# Account-binding proof: the full claim ceremony (fresh key → human approval
# on the verify page → possession-proof token poll), a wire call as the bound
# assistant account, the human-initiated link-code redeem, and unlink.
# Prints a JSON result line on stdout; the shell asserts each field.
require "jwt"; require "json"; require "net/http"; require "uri"; require "openssl"; require "securerandom"; require "base64"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")
HUMAN  = ENV.fetch("HUMAN_USER_ID")   # seeded account holder (alice)
USER_SESSION = "user:u-#{HUMAN}"      # StubUserIdp web-session channel

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
rc, da = post_json("#{SERVER}/kiosk/oauth/device_authorization", { client_id: "e2e-claim-flow", public_key: pem })
abort "device_authorization failed: #{rc} #{da}" unless rc == 200
device_code = da.fetch("device_code")
user_code   = da.fetch("user_code")
results[:da_fields] = %w[device_code user_code verification_uri expires_in interval].all? { |k| da.key?(k) }

# Poll with a valid proof before approval → authorization_pending.
rc, tok = post_form(TOKEN_URL, { grant_type: GRANT, device_code: device_code, signed: pop_proof(key, pem) })
results[:pending] = [rc, tok["error"]]

# The human approves on the verify page: GET first (session cookie + CSRF
# token when the host app enforces forgery protection), then POST approve.
verify_uri = URI("#{SERVER}/kiosk/oauth/device/verify?user_code=#{user_code}")
show = Net::HTTP.new(verify_uri.host, verify_uri.port)
               .request(Net::HTTP::Get.new(verify_uri, { "Authorization" => USER_SESSION }))
abort "verify page: #{show.code}" unless show.code.to_i == 200
cookie = Array(show.get_fields("set-cookie")).map { |c| c.split(";").first }.join("; ")
csrf   = show.body[/name="authenticity_token" value="([^"]+)"/, 1]
form = { user_code: user_code, decision: "approve" }
form[:authenticity_token] = csrf if csrf
headers = { "Authorization" => USER_SESSION }
headers["Cookie"] = cookie unless cookie.empty?
rc, = post_form("#{SERVER}/kiosk/oauth/device/verify", form, headers)
results[:approve] = rc

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
rc, link = post_json("#{SERVER}/kiosk/auth/link", {}, { "Authorization" => USER_SESSION })
results[:link_mint] = rc
rc, claim = post_json("#{SERVER}/kiosk/auth/claim",
                      { code: link.fetch("link_code", ""), public_key: pem2, signed: pop_proof(key2, pem2) })
results[:link_claim] = [rc, claim["user_id"] == HUMAN]

# ── unlink the first assistant: registration-layer revocation ──
rc, = post_json("#{SERVER}/kiosk/auth/unlink", { agent_id: agent_id }, { "Authorization" => USER_SESSION })
results[:unlink] = rc
rc, = post_json("#{SERVER}/kiosk/auth/login", { public_key: pem, signed: pop_proof(key, pem) })
results[:login_after_unlink] = rc

puts JSON.generate(results)
