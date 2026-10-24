# frozen_string_literal: true

require 'jwt'

module Kiosk
  module Server
    # Verifies a KYC attestation JWS against the configured `kyc_provider`: its
    # key signs it, its `iss` and `aud` match, `sub` and `level: "verified"`
    # match, and the provider accepts it; only attributes that are literally
    # `true` are granted.
    module KycVerifier
      # Named once for the decode and the published hint.
      REQUIRED_CLAIMS = %w[exp iss aud sub].freeze
      SIGNATURE_HINT  = 'an attestation is a compact EdDSA JWS signed by the issuer this origin ' \
                        'is configured to trust'
      SUBJECT_HINT    = "sub must name the principal: the caller's at POST <endpoint>/agents/kyc, " \
                        "the open verification's at the callback"

      module_function

      def verify(raw_jws:, subject:)
        provider = provider!
        payload  = decode(raw_jws, provider)
        check_issuer!(payload, provider)
        # Binds the attestation to this operator.
        if payload[:aud].to_s != provider.audience
          raise Errors::Forbidden.new('KYC attestation audience mismatch',
                                      hint: audience_hint(payload, provider))
        end

        check_subject!(payload, subject)
        check_provider!(payload, provider)

        payload.merge(attributes: verified_attributes(payload[:attributes]))
      end

      # The names granted as literal `true`; `{}` when absent; a non-object
      # is refused.
      def verified_attributes(raw)
        return {} if raw.nil?

        raise Errors::Forbidden, 'KYC attestation attributes must be an object of {name: true} booleans' unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(name, value), acc|
          acc[name.to_s] = true if value == true
        end
      end

      # The verified payload with symbol keys.
      def decode(raw_jws, provider)
        payload, = ::JWT.decode(raw_jws, provider.public_key, true,
                                algorithms: [Eddsa::NAME], verify_expiration: true, required_claims: REQUIRED_CLAIMS)
        payload.transform_keys(&:to_sym)
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden, 'KYC attestation expired'
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Forbidden.new('KYC attestation missing a required claim', hint: "an attestation carries #{REQUIRED_CLAIMS.join(', ')}")
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new('KYC attestation signature invalid', hint: SIGNATURE_HINT)
      end

      # Refused when this origin trusts no KYC provider.
      def provider!
        provider = Kiosk.configuration.kyc_provider
        return provider unless provider.nil?

        raise Errors::ModuleNotServed.new(
          'this operator does not serve the KYC module',
          hint: 'no KYC attestation is accepted at this origin; retrying will not help. ' \
                'An operator that means to serve KYC sets Kiosk.configuration.kyc_provider.'
        )
      end

      def check_issuer!(payload, provider)
        return if payload[:iss] == provider.issuer

        raise Errors::Forbidden.new(
          'KYC attestation issuer mismatch',
          hint: "expected #{provider.issuer.inspect}, got #{payload[:iss].inspect}"
        )
      end

      def audience_hint(payload, provider)
        "aud must equal the audience this operator's KYC provider mints " \
          "(expected #{provider.audience.inspect}, got #{payload[:aud].inspect})"
      end

      # Subject and level. A bigint-PK host's subject is an Integer.
      def check_subject!(payload, subject)
        raise Errors::Forbidden.new('KYC attestation subject mismatch', hint: SUBJECT_HINT) unless payload[:sub].to_s == subject.to_s

        raise Errors::Forbidden, 'kyc level not verified' unless payload[:level] == 'verified'
      end

      # The provider's own checks ({Kiosk::KycProviders::Base#accepts?}).
      def check_provider!(payload, provider)
        return if provider.accepts?(payload.transform_keys(&:to_s))

        raise Errors::Forbidden, 'the KYC provider does not accept this attestation at this operator'
      end

      private_class_method :decode, :provider!, :check_issuer!, :audience_hint, :check_subject!, :check_provider!
    end
  end
end
