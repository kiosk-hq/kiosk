# frozen_string_literal: true

module Kiosk
  module KycProviders
    # The provider did not open a verification now; a later attempt may.
    Unavailable = Class.new(StandardError)

    # Port for a KYC provider (`kiosk-kyc-*`); kiosk-server serves `request_kyc`
    # whenever `Kiosk.configuration.kyc_provider` is set.
    class Base
      # The provider later POSTs `{request_id, nonce, kyc_jws}` to `callback_url`.
      # @return [Hash] `request_id:`, `verification_url:`, `nonce:`
      # @raise [Unavailable]
      def open_verification(subject:, claims:, audience:, callback_url:) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#open_verification must be implemented by the adapter"
      end

      # Provider-specific checks after the engine verified signature, iss, aud, sub, level and exp.
      def accepts?(_payload) = true
    end
  end
end
