# frozen_string_literal: true

module Kiosk
  module AgentIdentityProviders
    # Base for an agent-IdP adapter fronting an external agent-identity issuer
    # (`c.agent_idp`). The `agent_id` it returns must be a uuid: every schema
    # column and `kiosk.current_agent_id()` are typed `uuid`, so map foreign ids.
    class Base
      # @return [Kiosk::Identity, nil] nil when the credential is absent or invalid (the caller answers 401)
      def verify(_request)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end

      # Not called yet: the built-in register/login endpoints mint via DefaultAgentIdp.
      def issue(agent_id:, role:)
        raise NotImplementedError, "#{self.class}#issue must be implemented by the adapter"
      end

      # The AP2 mandate-signing public key bound to this agent.
      def agent_payment_key(_agent_id)
        raise NotImplementedError, "#{self.class}#agent_payment_key must be implemented by the adapter"
      end
    end

    class InvalidToken < StandardError; end
  end
end
