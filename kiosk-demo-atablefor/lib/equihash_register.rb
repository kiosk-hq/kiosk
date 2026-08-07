# frozen_string_literal: true

# Shared registration helper for the atablefor demo flows.
#
# Registration is gated by ONE Equihash proof (see config/initializers/kiosk.rb).
# This helper does the full handshake: challenge → sign PoP → register; on a 402
# it solves every challenge with the shipped Python solver and retries the SAME
# register body, sending the proof(s) in the Kiosk-PoW request header as raw JSON
# (ADR-0022). Replaces the old inline SHA256 hashcash.
#
# Requires: json, jwt, net/http, uri, openssl, open3, securerandom (the caller
# already requires most of these).

require "open3"

EQUIHASH_REGISTER_SOLVE_PY = File.expand_path("../../kiosk-pow-equihash/solve.py", __dir__)

# Solve one Equihash challenge with the shipped solver → proof nonce hash.
def equihash_solve(challenge)
  out, status = Open3.capture2("python3", EQUIHASH_REGISTER_SOLVE_PY, JSON.generate(challenge))
  abort "solve.py exited non-zero: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# Register a fresh agent through the Equihash-gated /auth/register.
#
# @param server [String] base URL (e.g. http://skooti.app:3003)
# @param issuer [String] issuer origin for the PoP `aud` claim
# @param get_json [#call] ->(url) { [code, body] }
# @param post_json [#call] ->(url, body, headers = {}) { [code, body] }
#   (the header slot carries the Kiosk-PoW proof on the retry)
# @return [Array(OpenSSL::PKey::RSA, Hash)] the keypair and the register response
def equihash_register(server:, issuer:, get_json:, post_json:)
  key = OpenSSL::PKey::RSA.generate(2048)
  pem = key.public_key.to_pem

  rc_ch, ch = get_json.call("#{server}/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(pem)}")
  abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200
  pop = JWT.encode(
    { aud: issuer, nonce: ch.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i },
    key, "RS256",
  )

  body = { public_key: pem, signed: pop }
  rc, reg = post_json.call("#{server}/kiosk/auth/register", body)

  if rc == 402
    # The PoP nonce is NOT consumed on a 402 (the gate runs before the
    # challenge is spent), so we resubmit the SAME signed proof + the PoW.
    challenges = reg.dig("error", "challenges")
    abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
    rc, reg = post_json.call(
      "#{server}/kiosk/auth/register", body, { "Kiosk-PoW" => JSON.generate(proofs) }
    )
  end

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg]
end
