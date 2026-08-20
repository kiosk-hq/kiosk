# frozen_string_literal: true

module Kiosk
  module Server
    # Identity resolution for the wire surface.
    #
    # The bundled kiosk-pop engine — {AgentIdentityProviders::DefaultAgentIdp}
    # — is the DEFAULT agent-IdP: it verifies the very tokens the built-in
    # register/login/revoke endpoints mint, so a zero-config install works
    # end-to-end. `Kiosk.configuration.agent_idp` OVERRIDES it (custom
    # adapter fronting an external agent-identity issuer). No demo sets it:
    # the tokens they authenticate are the ones this engine minted (T-104).
    #
    # {.resolve} is the wire chain: the agent IdP first; when it yields no
    # identity (no/foreign credential — adapters return nil, they do not
    # raise), the provider's `user_idp` (its existing session auth: Devise
    # etc.) gets a chance, so a provider's own web/mobile frontend can call
    # the same endpoints. Nothing resolves → the caller raises 401.
    module IdentityResolution
      module_function

      # The effective agent-IdP: the configured override or the bundled
      # kiosk-pop default. Stateless — safe to build per call.
      def agent_idp
        Kiosk.configuration.agent_idp || AgentIdentityProviders::DefaultAgentIdp.new
      end

      # Try the agent IdP, then the user IdP. Returns {Kiosk::Identity} or nil.
      def resolve(request)
        identity = agent_idp.verify(request)
        return identity if identity

        Kiosk.configuration.user_idp&.verify(request)
      end
    end
  end
end
