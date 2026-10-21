# frozen_string_literal: true

module Kiosk
  module Server
    # A refusal on an `/oauth/*` endpoint, answered as `{error, error_description}`
    # (RFC 6749 Section 5.2, RFC 7591 Section 3.2.2), never as a problem document.
    class OauthError < StandardError
      # The token and device-authorization codes, and the registration code.
      CODES = %w[
        invalid_request invalid_client invalid_grant unsupported_grant_type invalid_dpop_proof
        authorization_pending slow_down expired_token access_denied
        invalid_client_metadata
      ].freeze

      attr_reader :code

      def initialize(code, description)
        @code = code.to_s
        raise ArgumentError, "#{@code} is not an OAuth error code of this origin" unless CODES.include?(@code)

        super(description)
      end

      # RFC 6749 Section 5.2: only a failed client authentication is a 401.
      def status = code == 'invalid_client' ? 401 : 400

      def to_h = { error: code, error_description: message }
    end
  end
end
