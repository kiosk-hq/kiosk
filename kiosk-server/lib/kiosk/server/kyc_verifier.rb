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
    # Checks: `level == "verified"` (case-sensitive — an unverified/other-level
    # attestation is rejected), correct issuer, `sub` matches the authenticated
    # identity (compared as String on both sides so a bigint-PK host works — see
    # K-092), and not expired. Raises `Errors::Forbidden` on any failure.
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

        payload, = ::JWT.decode(
          raw_jws, key, true,
          algorithms:       ["RS256"],
          verify_expiration: true,
          required_claims:  ["exp", "iss", "sub"],
        )
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != config.kyc_issuer
          raise Errors::Forbidden.new(
            "KYC attestation issuer mismatch",
            hint: "expected #{config.kyc_issuer.inspect}, got #{payload[:iss].inspect}",
          )
        end

        # Compare the principal as STRING on BOTH sides (K-092, mirroring
        # MandateVerifier). On a bigint-PK host the authenticated Identity
        # carries the raw Integer that the token `sub` round-trips as, while the
        # KYC provider signs `sub` with whatever id it was handed (a String). A
        # strict `==` ("42" == 42) is always false, so every KYC attestation on
        # a bigint host was wrongly Forbidden. Normalising keeps uuid hosts as-is.
        unless payload[:sub].to_s == identity.user_id.to_s
          raise Errors::Forbidden.new(
            "KYC attestation subject mismatch",
            hint: "sub must equal the authenticated user_id",
          )
        end

        # I1: require the KYC level to be exactly "verified" (case-sensitive).
        unless payload[:level] == "verified"
          raise Errors::Forbidden.new("kyc level not verified")
        end

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("KYC attestation expired")
      rescue ::JWT::MissingRequiredClaim => e
        raise Errors::Forbidden.new("KYC attestation missing required claim: #{e.message}")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("KYC attestation signature invalid: #{e.message}")
      end
    end
  end
end
