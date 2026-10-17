# frozen_string_literal: true

require 'openssl'
require 'jwt'

# The broker's signing key. Operators trust its public half, so every claim it
# signs is an anonymized attestation they accept: booleans only, bound to one
# subject, one operator's audience and one request.
module ProveKey
  LIFETIME = 365 * 24 * 3600

  module_function

  def issuer = Rails.configuration.x.prove.issuer
  def keypair = @keypair ||= OpenSSL::PKey::RSA.new(Rails.configuration.x.prove.key_pem)
  def public_key = keypair.public_key.to_pem

  # The claim for one approved request: its subject, operator, audience and nonce.
  def mint(prove_request, attributes)
    now = Time.now.to_i
    operator = prove_request.operator_id.to_s
    JWT.encode(
      { sub: prove_request.subject_handle.to_s, level: 'verified', iss: issuer, operator: operator,
        aud: prove_request.audience.presence || operator, request_id: prove_request.request_id.to_s,
        nonce: prove_request.nonce.to_s, attributes: attributes, iat: now, exp: now + LIFETIME },
      keypair, 'RS256'
    )
  end
end
