# frozen_string_literal: true

require 'jwt'

module Kiosk
  module Server
    # Verifies a KYC attestation JWS against `kyc_public_key`: `iss`, `aud`,
    # `sub` and `level: "verified"` must match, and the configured
    # `kyc_provider` must accept it; only attributes
    # that are literally `true` are granted.
    module KycVerifier
      # Named once for the decode and the published hint.
      REQUIRED_CLAIMS = %w[exp iss aud sub].freeze
      SIGNATURE_HINT  = 'an attestation is a compact RS256 JWS signed by the issuer this origin ' \
                        'is configured to trust'
      SUBJECT_HINT    = "sub must name the principal: the caller's at POST <endpoint>/agents/kyc, " \
                        "the open verification's at the callback"

      module_function

      def verify(raw_jws:, subject:)
        config  = Kiosk.configuration
        payload = decode(raw_jws, config)
        check_issuer!(payload, config)
        # Binds the attestation to this operator.
        if payload[:aud].to_s != config.kyc_audience.to_s
          raise Errors::Forbidden.new('KYC attestation audience mismatch',
                                      hint: audience_hint(payload, config))
        end

        check_subject!(payload, subject)
        check_provider!(payload, config)

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
      def decode(raw_jws, config)
        payload, = ::JWT.decode(raw_jws, public_key!(config), true,
                                algorithms: ['RS256'], verify_expiration: true, required_claims: REQUIRED_CLAIMS)
        payload.transform_keys(&:to_sym)
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden, 'KYC attestation expired'
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Forbidden.new('KYC attestation missing a required claim', hint: "an attestation carries #{REQUIRED_CLAIMS.join(', ')}")
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new('KYC attestation signature invalid', hint: SIGNATURE_HINT)
      end

      # Refused when this origin trusts no KYC issuer.
      def public_key!(config)
        key = config.kyc_public_key
        return key unless key.nil?

        raise Errors::ModuleNotServed.new(
          'this operator does not serve the KYC module',
          hint: 'no KYC attestation is accepted at this origin; retrying will not help. ' \
                'An operator that means to serve KYC sets Kiosk.configuration.kyc_public_key.'
        )
      end

      def check_issuer!(payload, config)
        return if payload[:iss] == config.kyc_issuer

        raise Errors::Forbidden.new(
          'KYC attestation issuer mismatch',
          hint: "expected #{config.kyc_issuer.inspect}, got #{payload[:iss].inspect}"
        )
      end

      def audience_hint(payload, config)
        "aud must equal this operator's kyc_audience " \
          "(expected #{config.kyc_audience.inspect}, got #{payload[:aud].inspect})"
      end

      # Subject and level. A bigint-PK host's subject is an Integer.
      def check_subject!(payload, subject)
        raise Errors::Forbidden.new('KYC attestation subject mismatch', hint: SUBJECT_HINT) unless payload[:sub].to_s == subject.to_s

        raise Errors::Forbidden, 'kyc level not verified' unless payload[:level] == 'verified'
      end

      # The provider's own checks ({Kiosk::KycProviders::Base#accepts?}).
      def check_provider!(payload, config)
        provider = config.kyc_provider
        return if provider.nil? || provider.accepts?(payload.transform_keys(&:to_s))

        raise Errors::Forbidden, 'the KYC provider does not accept this attestation at this operator'
      end

      private_class_method :decode, :public_key!, :check_issuer!, :audience_hint, :check_subject!, :check_provider!
    end
  end
end
