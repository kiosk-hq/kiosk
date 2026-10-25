# frozen_string_literal: true

module Kiosk
  module AgentIdentityProviders
    # Base for an agent-IdP adapter fronting an external agent-identity issuer
    # (`c.agent_idp`). The engine calls only `verify`: it mints tokens and reads
    # mandate-signing keys through its bundled DefaultAgentIdp. The `agent_id` it
    # returns must be a uuid: every `agent_id` column and `kiosk_current_agent_id()`
    # are typed `uuid`, so map foreign ids. The token comes as
    # `Authorization: DPoP <token>`, and the identity's `claims` carry
    # `cnf: { jkt: }`, the thumbprint of the key that must sign the request's
    # DPoP proof (RFC 9449).
    class Base
      # @return [Kiosk::Identity, nil] nil when the credential is absent or invalid (the caller answers 401)
      def verify(_request)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end
    end

    class InvalidToken < StandardError; end
  end
end
