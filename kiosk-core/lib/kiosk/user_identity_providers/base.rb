# frozen_string_literal: true

module Kiosk
  module UserIdentityProviders
    # Abstract base for user-IdP adapters.
    # See design spec §6.4.
    #
    # A user-IdP CONSUMES whatever already authenticates the principal at
    # the provider. The principal is typically a human, but equally a
    # synthetic placeholder, service account, team / org, or parent agent
    # depending on the adapter — see spec §6.1.
    #
    # Embedded-mode adapters: `kiosk-user-idp-devise`, `kiosk-user-idp-warden`.
    # Satellite-mode adapters: `kiosk-user-idp-jwt-bearer`,
    # `kiosk-user-idp-pg-session`, `kiosk-user-idp-oidc-generic`, etc.
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
