# frozen_string_literal: true

module Kiosk
  module KycProviders
    # The provider did not open a verification now; a later attempt may.
    Unavailable = Class.new(StandardError)

    # Port for a KYC provider (`kiosk-kyc-*` gems). kiosk-server serves
    # `request_kyc` and the provider callback against it whenever
    # `Kiosk.configuration.kyc_provider` is set.
    class Base
      # Opens a verification of `claims` for `subject` at the provider. The
      # provider later POSTs `{request_id, nonce, kyc_jws}` to `callback_url`.
      #
      # @param subject [String] the principal the attestation's `sub` must name
      # @param claims [Array<String>] attribute names, e.g. %w[age_over_18]
      # @param audience [String] the `aud` the attestation must carry
      # @param callback_url [String] the engine's callback
      # @return [Hash] `request_id:`, `verification_url:`, `nonce:` (Strings)
      # @raise [Unavailable] when the provider did not open one
      def open_verification(subject:, claims:, audience:, callback_url:) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#open_verification must be implemented by the adapter"
      end

      # Provider-specific checks on an attestation the engine has already
      # verified (signature, iss, aud, sub, level, exp).
      #
      # @param payload [Hash] the decoded attestation, String keys
      def accepts?(_payload) = true
    end
  end
end
