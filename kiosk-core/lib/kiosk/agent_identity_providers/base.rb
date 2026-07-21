# frozen_string_literal: true

module Kiosk
  module AgentIdentityProviders
    # Abstract base for agent-IdP adapters.
    #
    # An agent-IdP MINTS and VERIFIES agent credentials. The bundled
    # `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp` (in kiosk-server)
    # ships as the default and is used with ZERO config: it registers agents
    # into the local `agents` table and signs tokens with the provider's own
    # JWKS. Fronting an EXTERNAL agent-identity issuer by subclassing this Base
    # is a PLANNED seam — no external `kiosk-agent-idp-*` adapter (Entra Agent
    # ID, Okta Agent Identity, Google Agent Passport, ID-JAG, …) ships yet.
    class Base
      # Verify an incoming HTTP request into a {Kiosk::Identity}.
      #
      # @param request [#headers, #env] HTTP request shape (the adapter
      #   extracts its credential — typically the `Authorization` header)
      # @return [Kiosk::Identity, nil] nil when the credential is absent,
      #   foreign, or invalid — the caller turns nil into 401; adapters
      #   should not let verification errors escape
      def verify(_request)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end

      # Issue a fresh agent token for a registered agent at the chosen role.
      #
      # 0.1: the built-in kiosk-pop endpoints (register / login / revoke)
      # mint via the bundled DefaultAgentIdp by design and do NOT
      # call a custom adapter's #issue; adapter-supplied issuance (Entra /
      # Okta / Passport-style, roles-from-IdP) is the 0.2 seam.
      #
      # @param agent_id [String] UUID in the provider's `agents` table
      # @param role [String, Symbol] active role for the issued token
      # @return [String] JWT or other wire-format token the adapter chooses
      def issue(agent_id:, role:)
        raise NotImplementedError, "#{self.class}#issue must be implemented by the adapter"
      end

      # Return the AP2 mandate-signing public key bound to this agent.
      # See the Payment (AP2 mandate chain) section of the spec.
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
