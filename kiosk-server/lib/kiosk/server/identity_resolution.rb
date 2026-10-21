# frozen_string_literal: true

module Kiosk
  module Server
    # The identity of a protocol or event-stream caller: the access token, read by
    # the configured agent IdP or the bundled one. A cookie session
    # reaches only the human-side pages and the binding endpoints.
    module IdentityResolution
      module_function

      def agent_idp
        Kiosk.configuration.agent_idp || AgentIdentityProviders::DefaultAgentIdp.new
      end

      # The identity of the token, once the request's DPoP proof shows the key
      # the token is bound to; nil with no valid token.
      # @raise [Errors::AccessTokenRefused] a valid token without that proof
      def resolve(request)
        identity = agent_idp.verify(request)
        return if identity.nil?

        Dpop.verify!(request.headers['DPoP'],
                     token: Dpop.token(request.headers['Authorization']), jkt: identity.claims.dig(:cnf, :jkt),
                     method: request.request_method, url: "#{Kiosk.current_issuer}#{request.path}")
        identity
      end
    end
  end
end
