# frozen_string_literal: true

module Kiosk
  module AgentIdentityProviders
    # Abstract base for agent-IdP adapters.
    # See design spec §6.4 «Pluggable IdP — two roles, two deployments».
    #
    # An agent-IdP MINTS and VERIFIES agent credentials. Subclasses ship as
    # `kiosk-agent-idp-*` gems (Microsoft Entra Agent ID, Okta Agent Identity,
    # Google Agent Passport, …) or as the bundled
    # `Kiosk::AgentIdentityProviders::DefaultAgentIdp` shipped in
    # kiosk-server, which registers agents into the local `agents` table and
    # signs tokens with the provider's own JWKS.
    class Base
      # Verify an incoming Authorization header into a {Kiosk::Identity}.
      #
      # @param authorization_header [String] raw value of HTTP `Authorization`
      # @return [Kiosk::Identity]
      # @raise [Kiosk::AgentIdentityProviders::InvalidToken] on signature
      #   or claims failure
      def verify(_authorization_header)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end

      # Issue a fresh agent token for a registered agent at the chosen role.
      # Used at registration completion and at refresh.
      #
      # @param agent_id [String] UUID in the provider's `agents` table
      # @param role [String, Symbol] active role for the issued token
      # @return [String] JWT or other wire-format token the adapter chooses
      def issue(agent_id:, role:)
        raise NotImplementedError, "#{self.class}#issue must be implemented by the adapter"
      end

      # Return the AP2 mandate-signing public key bound to this agent.
      # See spec §5.5 «Identity ↔ AP2 keys».
      #
      # @param agent_id [String]
      # @return [Object] public key suitable for JWS verification
      def agent_payment_key(_agent_id)
        raise NotImplementedError, "#{self.class}#agent_payment_key must be implemented by the adapter"
      end
    end

    # Raised by adapters when a token fails signature, claims, or freshness.
    class InvalidToken < StandardError; end
  end
end
