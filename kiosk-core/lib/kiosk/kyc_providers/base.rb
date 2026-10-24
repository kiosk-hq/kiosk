# frozen_string_literal: true

require 'openssl'

module Kiosk
  module KycProviders
    # The provider did not open a verification now; a later attempt may.
    class Unavailable < StandardError
    end

    # The KYC provider an operator trusts, set as `Kiosk.configuration.kyc_provider`.
    # It names the issuer, the Ed25519 key and the audience that the engine
    # checks every attestation against. A `Base` accepts attestations at
    # `POST <endpoint>/agents/kyc` only; an adapter (`kiosk-kyc-*`) that opens
    # verifications also serves `request_kyc`.
    class Base
      attr_reader :issuer, :public_key

      # @param issuer [String] the `iss` the provider signs
      # @param public_key [OpenSSL::PKey::PKey, String] its Ed25519 public key, or the key's PEM
      # @param audience [String, nil] the `aud` it mints for this operator; nil: the origin being served
      def initialize(issuer:, public_key:, audience: nil)
        @issuer     = issuer.to_s
        @public_key = public_key.is_a?(String) ? OpenSSL::PKey.read(public_key) : public_key
        @audience   = audience
        return if @public_key.is_a?(OpenSSL::PKey::PKey) && @public_key.oid == 'ED25519'

        raise ArgumentError, "a KYC provider's public_key must be an Ed25519 key or its PEM, got #{@public_key.class}"
      end

      def audience = (@audience || Kiosk.current_issuer).to_s

      # True when the provider opens verifications, so the engine serves `request_kyc`.
      def opens_verifications? = false

      # The provider later POSTs `{request_id, nonce, kyc_jws}` to `callback_url`.
      # @return [Hash] `request_id:`, `verification_url:`, `nonce:`
      # @raise [Unavailable]
      def open_verification(subject:, claims:, callback_url:)
        raise NotImplementedError, "#{self.class}#open_verification must be implemented by the adapter"
      end

      # Provider-specific checks after the engine verified signature, iss, aud, sub, level and exp.
      def accepts?(_payload) = true
    end
  end
end
