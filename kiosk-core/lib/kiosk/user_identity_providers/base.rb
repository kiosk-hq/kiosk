# frozen_string_literal: true

module Kiosk
  module UserIdentityProviders
    # Abstract base for user-IdP adapters.
    #
    # A user-IdP CONSUMES whatever already authenticates the principal at
    # the provider. The principal is typically a human, but equally a
    # synthetic placeholder, service account, team / org, or parent agent
    # depending on the adapter.
    #
    # Adapters ship as `kiosk-user-idp-*` gems. Today only
    # `kiosk-user-idp-devise` (embedded mode) ships; further embedded and
    # satellite-mode adapters (Warden, JWT-bearer, pg-session, generic OIDC,
    # …) are planned — none exist yet.
    class Base
      # Verify an incoming request into a {Kiosk::Identity}.
      #
      # @param request [#headers, #env] HTTP request shape (Rack-compatible
      #   in embedded mode; opaque to adapter in satellite mode)
      # @return [Kiosk::Identity, nil] identity if authenticated; nil otherwise
      def verify(_request)
        raise NotImplementedError, "#{self.class}#verify must be implemented by the adapter"
      end

      # Optional callback for immediate revocation on satellite/JWT paths.
      # Default no-op (TTL-based revocation). Override to add a per-request
      # check of users.locked_at / users.confirmed_at / etc.
      #
      # @param user_id [String, Integer]
      # @return [Boolean]
      def user_active?(_user_id)
        true
      end
    end
  end
end
