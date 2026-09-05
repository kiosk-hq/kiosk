# frozen_string_literal: true

# Combette / stylish registration-PoW driver.
#
# Proves the Equihash registration gate (ALWAYS ON — wired in the app config, no
# env flag): POST /auth/register with no proof returns 402; the agent solves the
# challenge(s) and resubmits the SAME signed body, sending the proof(s) in the
# Kiosk-PoW request header, getting 201. Then queries `salons`. One JSON line on stdout.
#
# Usage (invoked by rake demo:register):
#   SERVER_URL=… KIOSK_ISSUER=… bundle exec ruby script/register_flow.rb
# Requires: python3 with numpy.

require "json"
require "jwt"
require "net/http"
require "uri"
require "openssl"
require "open3"
require "securerandom"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

# equihash_solve comes from the shared helper (solver location owned by the
# kiosk-pow-equihash gem). The full equihash_register handshake it also
# defines is deliberately NOT used here: this driver spells out the 402 →
# solve → resubmit choreography step by step and asserts each status.
require_relative "equihash_register"

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

# ── Challenge + PoP ─────────────────────────────────────────────────────────
key = OpenSSL::PKey::RSA.generate(2048)
pem = key.public_key.to_pem
rc_ch, ch = get_json("#{SERVER}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
pop = JWT.encode({ aud: ISSUER, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
reg_body = { public_key: pem, signed: pop }

# ── Register with no proof → expect 402 pow_required ────────────────────────
rc_nopow, resp_nopow = post_json("#{SERVER}/kiosk/auth/register", reg_body)
abort "expected 402 without proof, got #{rc_nopow}: #{JSON.generate(resp_nopow)}" unless rc_nopow == 402
# The 402 is an RFC 9457 problem document: `challenges` is a TOP-LEVEL
# extension member, not nested under an `error` object.
challenges = resp_nopow["challenges"]
abort "402 without challenges[]" unless challenges.is_a?(Array) && challenges.any?

# ── Solve and resubmit the SAME signed body → expect 201 ────────────────────
proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
rc_reg, reg = post_json("#{SERVER}/kiosk/auth/register", reg_body, { "Kiosk-PoW" => JSON.generate(proofs) })
abort "register with proof failed (#{rc_reg}): #{JSON.generate(reg)}" unless rc_reg == 201
token = reg.fetch("access_token")

# ── Use the fresh token: query salons → 200 ─────────────────────────────────
# A query is a GET at its own endpoint and its answer IS the rows — a bare JSON
# array, with no `{"rows": …}` envelope to unwrap.
rc_q, q = get_json("#{SERVER}/kiosk/salons", { "Authorization" => "Bearer #{token}" })
abort "salons query failed (#{rc_q}): #{JSON.generate(q)}" unless rc_q == 200
salons = Array(q)

puts JSON.generate(
  http_register_no_pow: rc_nopow,
  http_register_solved: rc_reg,
  proofs_solved:        proofs.size,
  http_salons:          rc_q,
  salons_rows:          salons.is_a?(Array) ? salons.size : 0,
)
