# frozen_string_literal: true

module Kiosk
  module Server
    # Resolves the caller: the agent IdP (configured, or the bundled kiosk-pop
    # one), then the operator's own `user_idp`.
    module IdentityResolution
      module_function

      def agent_idp
        Kiosk.configuration.agent_idp || AgentIdentityProviders::DefaultAgentIdp.new
      end

      def resolve(request)
        identity = agent_idp.verify(request)
        return identity if identity

        Kiosk.configuration.user_idp&.verify(request)
      end
    end
  end
end
