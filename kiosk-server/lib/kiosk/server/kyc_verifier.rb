# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies a KYC attestation JWS against `kyc_public_key`: `iss`, `aud`,
    # `sub` and `level: "verified"` must match; only attributes
    # that are literally `true` are granted.
    module KycVerifier
      # Named once for the decode and the published hint.
      REQUIRED_CLAIMS = %w[exp iss aud sub].freeze

      module_function

      def verify(raw_jws:, subject:)
        config = Kiosk.configuration
        key    = config.kyc_public_key

        raise Errors::ModuleNotServed.new(
          "this operator does not serve the KYC module",
          hint: "no KYC attestation is accepted at this origin; retrying will not help. " \
                "An operator that means to serve KYC sets Kiosk.configuration.kyc_public_key.",
        ) if key.nil?

        payload, = ::JWT.decode(
          raw_jws, key, true,
          algorithms:       ["RS256"],
          verify_expiration: true,
          required_claims:  REQUIRED_CLAIMS,
        )
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != config.kyc_issuer
          raise Errors::Forbidden.new(
            "KYC attestation issuer mismatch",
            hint: "expected #{config.kyc_issuer.inspect}, got #{payload[:iss].inspect}",
          )
        end

        # Binds the attestation to this operator.
        if payload[:aud].to_s != config.kyc_audience.to_s
          raise Errors::Forbidden.new(
            "KYC attestation audience mismatch",
            hint: "aud must equal this operator's kyc_audience " \
                  "(expected #{config.kyc_audience.inspect}, got #{payload[:aud].inspect})",
          )
        end

        # A bigint-PK host's subject is an Integer.
        unless payload[:sub].to_s == subject.to_s
          raise Errors::Forbidden.new(
            "KYC attestation subject mismatch",
            hint: "sub must name the principal: the caller's at POST <endpoint>/agents/kyc, " \
                  "the open verification's at the callback",
          )
        end

        unless payload[:level] == "verified"
          raise Errors::Forbidden.new("kyc level not verified")
        end

        payload[:attributes] = verified_attributes(payload[:attributes])

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("KYC attestation expired")
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Forbidden.new(
          "KYC attestation missing a required claim",
          hint: "an attestation carries #{REQUIRED_CLAIMS.join(", ")}",
        )
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new(
          "KYC attestation signature invalid",
          hint: "an attestation is a compact RS256 JWS signed by the issuer this origin " \
                "is configured to trust",
        )
      end

      # The names granted as literal `true`; `{}` when absent; a non-object
      # is refused.
      def verified_attributes(raw)
        return {} if raw.nil?

        unless raw.is_a?(Hash)
          raise Errors::Forbidden.new(
            "KYC attestation attributes must be an object of {name: true} booleans",
          )
        end

        raw.each_with_object({}) do |(name, value), acc|
          acc[name.to_s] = true if value == true
        end
      end
    end
  end
end
