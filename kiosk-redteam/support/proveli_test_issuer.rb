# frozen_string_literal: true

require 'openssl'
require 'jwt'
require 'kiosk/server/eddsa'

# Signs KYC attestations as the broker does, for the operator `skooti`, with
# the broker's development key, so an attack can attest a customer without the
# broker's round trip. The key ships
# in this public repository, so it never signs under production.
module ProveliTestIssuer
  KEY = File.expand_path('../../kiosk-demo-proveli/config/dev_proveli_key.pem', __dir__)

  module_function

  def keypair
    raise 'ProveliTestIssuer signs with a public development key' if ENV['RAILS_ENV'] == 'production'

    @keypair ||= OpenSSL::PKey.read(File.read(KEY))
  end

  def issuer = 'https://kyc.test.local'
  def audience = 'skooti'

  def attest(user_id:, attributes: nil) = sign(user_id, Time.now.to_i, attributes)
  def attest_expired(user_id:) = sign(user_id, Time.now.to_i - 7200)

  def sign(user_id, issued_at, attributes = nil)
    claims = { sub: user_id.to_s, level: 'verified', iss: issuer, aud: audience, operator: audience,
               iat: issued_at, exp: issued_at + 3600 }
    JWT.encode(attributes ? claims.merge(attributes:) : claims, keypair, 'EdDSA')
  end
end
