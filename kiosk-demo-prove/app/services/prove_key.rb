# frozen_string_literal: true

require "openssl"
require "jwt"

# The broker's signing key. Operators trust its public half, so every claim it
# signs is an anonymized attestation they accept: booleans only, bound to one
# subject, one operator's audience and one request.
module ProveKey
  LIFETIME = 365 * 24 * 3600

  module_function

  def issuer = Rails.configuration.x.prove.issuer
  def keypair = @keypair ||= OpenSSL::PKey::RSA.new(Rails.configuration.x.prove.key_pem)
  def public_key = keypair.public_key.to_pem

  def mint(subject:, operator:, attributes:, request_id:, nonce:, audience: nil)
    now = Time.now.to_i
    JWT.encode(
      { sub: subject.to_s, level: "verified", iss: issuer, operator: operator.to_s,
        aud: audience.presence || operator.to_s, request_id: request_id.to_s, nonce: nonce.to_s,
        attributes: attributes, iat: now, exp: now + LIFETIME },
      keypair, "RS256",
    )
  end
end
