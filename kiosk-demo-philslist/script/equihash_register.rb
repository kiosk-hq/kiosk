# frozen_string_literal: true

# Agent registration through the Equihash toll, for the philslist demo drivers.

require "kiosk/pow/equihash/solver"

def equihash_solve(challenge)
  Kiosk::Pow::Equihash.solve(challenge)
rescue Kiosk::Pow::Equihash::SolverError => e
  abort e.message
end

# Sends the request; on a 402, solves every challenge and resends with the proofs in the Kiosk-PoW header.
def through_toll
  answer = yield({})
  rc, body = answer
  return answer unless rc == 402

  challenges = body["challenges"]
  abort "402 without challenges[]: #{JSON.generate(body)}" unless challenges.is_a?(Array) && challenges.any?
  proofs = challenges.map { |c| { challenge: c, nonce: equihash_solve(c) } }
  yield({ "Kiosk-PoW" => JSON.generate(proofs) })
end

# Returns [key, register response, status code].
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
  # A 402 does not spend the challenge, so the retry resubmits the same signed proof.
  rc, reg = through_toll { |toll| post_json.call("#{server}/kiosk/auth/register", body, toll) }

  abort "register failed (#{rc}): #{JSON.generate(reg)}" unless rc == 201
  [key, reg, rc]
end
