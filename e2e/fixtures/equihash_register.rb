# frozen_string_literal: true

# Shared registration helper for the e2e flows.
#
# Registration is gated by ONE Equihash proof (see initializer_kiosk.rb:
# registration_pow_count = 1, params n=96 k=5). This helper does the full
# handshake: challenge → sign PoP → register; on a 402 pow_required it solves
# every challenge with the shipped Python solver and retries the SAME register
# body, sending the proof(s) in the Kiosk-PoW request header as raw JSON
# (ADR-0022). Same mechanism the demos use
# (kiosk-demo-skooti/lib/equihash_register.rb).
#
# Requires: json, jwt, openssl, securerandom, uri, open3 (callers already
# require most of these). Callers supply get_json/post_json lambdas so the
# helper stays transport-agnostic.
#
# The solver is located via SOLVE_PY (set by run.sh/assistant.sh to
# $KIOSK_OSS/kiosk-pow-equihash/solve.py) — it is NOT copied into the app.

require "open3"

E2E_SOLVE_PY = ENV.fetch("SOLVE_PY") do
  # Fallback for direct invocation from a sibling checkout layout.
  File.expand_path("../../kiosk-pow-equihash/solve.py", __dir__)
end

# Solve one Equihash challenge with the shipped solver → proof nonce.
def equihash_solve(challenge)
  out, status = Open3.capture2("python3", E2E_SOLVE_PY, JSON.generate(challenge))
  abort "solve.py exited non-zero: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# Register a fresh agent through the Equihash-gated /auth/register.
#
# @param server   [String]  base URL (e.g. http://127.0.0.1:3001)
# @param issuer   [String]  issuer origin for the PoP `aud` claim
# @param get_json  [#call]  ->(url) { [code, body] }
# @param post_json [#call]  ->(url, body, headers = {}) { [code, body] }
#   (the header slot carries the Kiosk-PoW proof on the retry)
# @return [Array(OpenSSL::PKey::RSA, Hash)] the keypair and the 201 register body
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
    # RFC 9457: the 402 is a problem document, so `challenges` is a TOP-LEVEL
    # extension member — there is no nested `error` object to reach into.
    challenges = reg["challenges"]
    abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
    rc, reg = post_json.call(
      "#{server}/kiosk/auth/register", body, { "Kiosk-PoW" => JSON.generate(proofs) }
    )
  end

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg]
end
