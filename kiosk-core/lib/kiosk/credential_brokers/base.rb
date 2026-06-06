# frozen_string_literal: true

module Kiosk
  module CredentialBrokers
    # Abstract base for KYC / verified-attribute broker adapters.
    # See design spec §5.6 «Verified credentials».
    #
    # Credential brokers are NOT auth — they issue verified-attribute
    # attestations (driver's licence category B, passport hash, phone E.164),
    # not identity tokens. Used in parallel with user-IdP, never in place
    # of it.
    #
    # Subclasses ship as `kiosk-credentials-*` gems (Persona, Onfido, Sumsub,
    # ID.me, ESIA). All open-source.
    class Base
      # Initiate a credential request for a user.
      # Returns an opaque session/inquiry id the agent can poll or follow
      # to the broker's UI.
      #
      # @param user_id [String, Integer]
      # @param attribute_kinds [Array<Symbol>] e.g.
      #   `[:driver_license_b, :age_18_plus]`
      # @return [Hash] `session_id`, `follow_url` (if applicable), `expires_at`
      def request(user_id:, attribute_kinds:)
        raise NotImplementedError, "#{self.class}#request must be implemented by the adapter"
      end

      # Verify a broker's JWS-signed attestation payload, typically delivered
      # via the `/kiosk/credentials/callback` webhook.
      #
      # @param signed_jws [String]
      # @return [Hash] verified attributes (claims), normalised to Kiosk's
      #   vocabulary
      def verify(_signed_jws)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end
    end
  end
end
