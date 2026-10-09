# frozen_string_literal: true

require "openssl"
require "jwt"

# Signs KYC attestations with the broker's development key, so a test or an
# attack can attest a principal without the broker's round trip. The key ships
# in this public repository, so it never signs under production.
module ProveTestIssuer
  KEY = File.expand_path("../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__)

  module_function

  def keypair
    raise "ProveTestIssuer signs with a public development key" if ENV["RAILS_ENV"] == "production"

    @keypair ||= OpenSSL::PKey::RSA.new(File.read(KEY))
  end

  def issuer = "https://kyc.test.local"
  def audience = "skooti"

  def attest(user_id:, attributes: nil) = sign(user_id, Time.now.to_i, attributes)
  def attest_expired(user_id:) = sign(user_id, Time.now.to_i - 7200)

  def sign(user_id, issued_at, attributes = nil)
    claims = { sub: user_id.to_s, level: "verified", iss: issuer, aud: audience, iat: issued_at, exp: issued_at + 3600 }
    JWT.encode(attributes ? claims.merge(attributes:) : claims, keypair, "RS256")
  end
end
