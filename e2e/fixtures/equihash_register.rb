# frozen_string_literal: true

# Shared registration helper for the e2e flows.
#
# Registration is gated by Equihash proofs — how MANY is the app's
# `registration_pow_count` and how BIG is its `E2E_REGISTRATION_POW_PARAMS`,
# both set in initializer_kiosk.rb and NEITHER RESTATED HERE: this helper reads
# neither, because it takes both off the 402
# it is answering, so a comment quoting them here could only ever be a second
# copy of a fact this file does not depend on. It does the full handshake:
# challenge → sign PoP → register; on a 402 pow_required it solves every
# challenge with the shipped Python solver and retries the SAME register body,
# sending the proof(s) in the Kiosk-PoW request header as raw JSON.
#
# Requires: json, jwt, openssl, securerandom, uri (callers already require most
# of these), and the caller's own `get_json(url, headers)` and
# `post_json(url, body, headers)`, which return `[code, body]`.
#
# The generated app bundles kiosk-pow-equihash, and that gem owns solve.py and
# knows where it is inside its own package — so nothing here, and nothing in
# run.sh, has to carry a path to it.

require 'kiosk/pow/equihash/solver'

# Solve one Equihash challenge with the solver kiosk-pow-equihash ships.
def equihash_solve(challenge)
  Kiosk::Pow::Equihash.solve(challenge)
rescue Kiosk::Pow::Equihash::SolverError => e
  abort e.message
end

# Register a fresh agent through the Equihash-gated /auth/register.
#
# @param server   [String]  base URL (e.g. http://127.0.0.1:3001)
# @param issuer   [String]  issuer origin for the PoP `aud` claim
# @param headers  [Hash]    sent on every request (e.g. a Host for a second origin)
# @param on_proofs [#call, nil] called with the proofs this helper sent, once the server accepted them
# @param key [OpenSSL::PKey::RSA] the keypair to register; a fresh one by default
# @return [Array(OpenSSL::PKey::RSA, Hash)] the keypair and the 201 register body
def equihash_register(server:, issuer:, headers: {}, on_proofs: nil, key: OpenSSL::PKey::RSA.generate(2048))
  pem  = key.public_key.to_pem
  body = { public_key: pem, signed: registration_pop(server, issuer, key, headers) }
  rc, reg = post_json("#{server}/kiosk/auth/register", body, headers)
  rc, reg = pay_registration_toll(server, body, reg, headers, on_proofs) if rc == 402

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg]
end

# A proof of possession of `key`, signed over a fresh server challenge.
def registration_pop(server, issuer, key, headers)
  pem = URI.encode_www_form_component(key.public_key.to_pem)
  rc_ch, ch = get_json("#{server}/kiosk/auth/challenge?public_key=#{pem}", headers)
  abort "challenge failed (#{rc_ch}): #{JSON.generate(ch)}" unless rc_ch == 200

  JWT.encode({ aud: issuer, nonce: ch.fetch('challenge'), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, 'RS256')
end

# Solves every challenge of the 402 and resubmits the SAME body: the PoP nonce
# is not consumed on a 402. RFC 9457: `challenges` is a top-level member.
def pay_registration_toll(server, body, problem, headers, on_proofs)
  challenges = problem['challenges']
  abort "402 without challenges[]: #{JSON.generate(problem)}" unless challenges.is_a?(Array) && challenges.any?

  proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  rc, reg = post_json("#{server}/kiosk/auth/register", body, headers.merge('Kiosk-PoW' => JSON.generate(proofs)))
  # Only proofs the server accepted say anything about the shape it requires.
  on_proofs&.call(proofs) if rc == 201
  [rc, reg]
end
