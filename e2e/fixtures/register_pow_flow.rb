# frozen_string_literal: true

# Register-PoW proof driver — the agent golden-path registration leg WITH a
# real register-time Equihash proof-of-work (the DoD-2 gap: e2e must exercise
# PoW-gated registration, not a toll-free shortcut).
#
# Proves, in one run against the live server:
#   1. A no-proof register is REJECTED with 402 pow_required + challenges[].
#   2. Solving every challenge (bundled numpy solver) and re-POSTing register
#      with the Kiosk-PoW header carrying [...] SUCCEEDS (201) and mints a usable token.
#   3. The minted token authenticates a real wire verb.
#
# Same mechanism the demos use (kiosk-demo-skooti). Emits ONE JSON line on
# stdout for assistant.sh to assert on; non-zero exit on any HTTP failure.
#
# Usage (invoked by assistant.sh — needs a running server + numpy on PATH):
#   SERVER_URL=… KIOSK_ISSUER=… SOLVE_PY=…/solve.py bundle exec ruby register_pow_flow.rb
require "jwt"; require "json"; require "net/http"; require "uri"; require "openssl"; require "securerandom"; require "base64"

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

require_relative "equihash_register"

results = {}

# ── 1. No-proof register is toll-gated (402 pow_required + challenges[]) ──────
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed: #{rc_ch} #{ch}" unless rc_ch == 200
pop = JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
rc_noproof, reg_noproof = post_json("#{SERVER}/kiosk/auth/register", { public_key: pem, signed: pop })
results[:no_proof_status] = rc_noproof
results[:no_proof_code]   = reg_noproof.dig("error", "code")
results[:challenges_len]  = Array(reg_noproof.dig("error", "challenges")).length

# ── 2. Solve the toll + register succeeds (fresh key via the shared helper) ──
reg_key, reg = equihash_register(
  server:    SERVER,
  issuer:    ISSUER,
  get_json:  ->(url) { get_json(url) },
  post_json: ->(url, body, headers = {}) { post_json(url, body, headers) },
)
token = reg.fetch("access_token")
results[:with_proof_registered] = !token.to_s.empty?
# The pinned registration_role rides inside the minted JWT claims (the 201 body
# is {agent_id, user_id, access_token} — no top-level role). Decode it to prove
# the agent got the server-pinned :customer role it never chose.
claims_seg = token.split(".")[1].to_s
claims = JSON.parse(Base64.urlsafe_decode64(claims_seg + "=" * ((4 - claims_seg.length % 4) % 4))) rescue {}
results[:role] = claims["role"]

# ── 3. The PoW-minted token authenticates a real wire verb ──────────────────
rc_wire, wire = post_json("#{SERVER}/kiosk/query", { name: "salons" }, { "Authorization" => "Bearer #{token}" })
results[:wire_status] = rc_wire
results[:wire_ok]     = wire["ok"]

puts JSON.generate(results)
