# frozen_string_literal: true

module Kiosk
  module Server
    # The identity of a wire or event-stream caller: the bearer token, read by
    # the configured agent IdP or the bundled kiosk-pop one. A cookie session
    # reaches only the human-side pages and the binding endpoints.
    module IdentityResolution
      module_function

      def agent_idp
        Kiosk.configuration.agent_idp || AgentIdentityProviders::DefaultAgentIdp.new
      end

      def resolve(request)
        agent_idp.verify(request)
      end
    end
  end
end
