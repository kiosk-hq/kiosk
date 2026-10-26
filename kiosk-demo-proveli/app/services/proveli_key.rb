# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'

# The broker's Ed25519 signing key. Operators trust its public half, so every
# claim it signs is an anonymized attestation they accept: booleans only, bound
# to one subject, one operator's audience and one request.
module ProveliKey
  LIFETIME = 365 * 24 * 3600

  module_function

  def issuer = Rails.configuration.x.proveli.issuer
  def keypair = @keypair ||= OpenSSL::PKey.read(Rails.configuration.x.proveli.key_pem)
  def public_key = keypair.public_to_pem

  # The claim for one approved request: its subject, operator, audience and nonce.
  def mint(proveli_request, attributes)
    now = Time.now.to_i
    jws({ sub: proveli_request.subject_handle.to_s, level: 'verified', iss: issuer, operator: proveli_request.operator_id.to_s,
          aud: proveli_request.audience, request_id: proveli_request.request_id.to_s,
          nonce: proveli_request.nonce.to_s, attributes: attributes, iat: now, exp: now + LIFETIME })
  end

  # A compact JWS (RFC 7515) signed EdDSA (RFC 8037).
  def jws(claims)
    input = [{ alg: 'EdDSA', typ: 'JWT' }, claims].map { b64(JSON.generate(it)) }.join('.')
    "#{input}.#{b64(keypair.sign(nil, input))}"
  end

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
end
