# frozen_string_literal: true

# Shared registration helper for the getgrocery demo flows.
#
# Registration is gated by ONE Equihash proof (see config/initializers/kiosk.rb).
# This helper does the full handshake: challenge → sign PoP → register; on a 402
# it solves every challenge with the shipped Python solver and retries the SAME
# register body, sending the proof(s) in the Kiosk-PoW request header as raw
# JSON rather than in the body — which is what lets a GET carry one too.
#
# IT LIVES IN script/, NOT IN lib/, AND THAT IS THE POINT. It is a FLOW-DRIVER
# helper — its only callers are the scripts in this directory and the demo rake
# tasks that run them — so it has no business in the Rails application's
# autoload path. In lib/ it would be loaded by `rails server` and then have to
# be hand-excluded again from `config.autoload_lib(ignore: …)`.
#
# Requires: json, jwt, net/http, uri, openssl, open3, securerandom (the caller
# already requires most of these) plus the kiosk-pow-equihash gem, which owns
# the solver's location.

require "open3"
require "kiosk/pow/equihash"

# Solve one Equihash challenge with the shipped solver → proof nonce hash.
# The solver path comes from Kiosk::Pow::Equihash.solver_path — the gem's
# documented accessor for solve.py inside its own package — instead of a
# checkout-relative constant here: one owner for the location.
def equihash_solve(challenge)
  out, status = Open3.capture2("python3", Kiosk::Pow::Equihash.solver_path, JSON.generate(challenge))
  abort "solve.py exited non-zero: #{out}" unless status.success?
  parsed = JSON.parse(out)
  abort "solve.py error: #{parsed["error"]}" if parsed.key?("error")
  { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
end

# Register a fresh agent through the Equihash-gated /auth/register.
#
# @param server [String] base URL (e.g. http://localhost:3001)
# @param issuer [String] issuer origin for the PoP `aud` claim
# @param get_json [#call] ->(url) { [code, body] }
# @param post_json [#call] ->(url, body, headers = {}) { [code, body] }
#   (the header slot carries the Kiosk-PoW proof on the retry)
# @return [Array(OpenSSL::PKey::RSA, Hash, Integer)] the keypair, the register
#   response, and the response CODE. The code is returned so a driver
#   that REPORTS `http_register` reports what the server actually answered
#   instead of writing `201` down beside a comment explaining why it must be
#   201 — a rake task cannot "assert" a constant the driver typed. It is the
#   third element, so the many callers that bind only `key, reg` are unaffected.
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
    #
    # The 402 is an RFC 9457 problem document (0.4 moved the auth plane onto
    # them with the wire): `challenges` is a TOP-LEVEL extension member, not
    # nested under an `error` object.
    challenges = reg["challenges"]
    abort "402 without challenges[]: #{JSON.generate(reg)}" unless challenges.is_a?(Array) && challenges.any?
    proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
    rc, reg = post_json.call(
      "#{server}/kiosk/auth/register", body, { "Kiosk-PoW" => JSON.generate(proofs) }
    )
  end

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg, rc]
end
