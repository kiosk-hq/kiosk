# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies a KYC attestation JWS submitted by an agent.
    #
    # Expected JWS payload:
    #   { sub: <user_id>, level: "verified", iss: <kyc_issuer>, iat: <unix>, exp: <unix> }
    #
    # Verified against `Kiosk.configuration.kyc_public_key` (RS256).
    # Checks: correct issuer, sub matches authenticated identity, not expired.
    # Raises `Errors::Forbidden` on any failure.
    module KycVerifier
      module_function

      # @param raw_jws  [String]          compact JWS string
      # @param identity [Kiosk::Identity] the authenticated principal
      # @return [Hash] symbol-keyed payload claims on success
      # @raise [Errors::Forbidden] on any verification failure
      def verify(raw_jws:, identity:)
        config = Kiosk.configuration
        key    = config.kyc_public_key

        raise Errors::Forbidden.new(
          "kyc_public_key not configured",
          hint: "Set Kiosk.configuration.kyc_public_key to the KYC provider's RSA public key",
        ) if key.nil?

        payload, = ::JWT.decode(raw_jws, key, true, algorithms: ["RS256"])
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != config.kyc_issuer
          raise Errors::Forbidden.new(
            "KYC attestation issuer mismatch",
            hint: "expected #{config.kyc_issuer.inspect}, got #{payload[:iss].inspect}",
          )
        end

        unless payload[:sub] == identity.user_id
          raise Errors::Forbidden.new(
            "KYC attestation subject mismatch",
            hint: "sub must equal the authenticated user_id",
          )
        end

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("KYC attestation expired")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("KYC attestation signature invalid: #{e.message}")
      end
    end
  end
end
