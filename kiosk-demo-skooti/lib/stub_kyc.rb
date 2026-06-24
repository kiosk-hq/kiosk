# frozen_string_literal: true

require "openssl"
require "jwt"

# Stub KYC provider for the skooti demo. Generates a memoized RSA keypair at
# load time and issues compact RS256 JWS attestations. Real providers swap
# in a properly-credentialled KYC service; the shape is identical.
#
# Class-level memoised key — generated once per process, stable across calls.
# StubKyc.public_key   → PEM string (configure in kiosk initializer)
# StubKyc.attest(user_id:) → compact JWS string (submit to POST /kiosk/agents/kyc)
class StubKyc
  KEYPAIR = OpenSSL::PKey::RSA.generate(2048)
  private_constant :KEYPAIR

  # The RSA public key PEM string — pass to Kiosk.configuration.kyc_public_key.
  def self.public_key
    KEYPAIR.public_key.to_pem
  end

  # Issue a KYC attestation JWS for the given user_id.
  #
  # @param user_id [String] the user's UUID
  # @return [String] compact RS256 JWS
  def self.attest(user_id:)
    now = Time.now.to_i
    payload = {
      sub:   user_id,
      level: "verified",
      iss:   "https://kyc.example",
      iat:   now,
      exp:   now + 3600,
    }
    JWT.encode(payload, KEYPAIR, "RS256")
  end
end
