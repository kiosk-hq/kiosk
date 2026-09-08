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

      # An UNUSED EXTENSION POINT. It was meant as the immediate-revocation
      # hook for the satellite/JWT paths — a per-request check of
      # users.locked_at / users.confirmed_at — but NOTHING in kiosk-server
      # calls it, so overriding it changes no answer on the wire. Revocation
      # today is TTL-based plus the per-identity revoked-before watermark
      # (`/auth/revoke`), and the human side is the host application's own IdP
      # (Devise's `active_for_authentication?` for the bundled adapter). Wiring
      # it would add a per-request query to every authenticated call — a
      # deliberate design decision, not an incidental change; until that
      # happens this stays here as the named seam a satellite deployment would
      # implement against.
      #
      # @param user_id [String, Integer]
      # @return [Boolean]
      def user_active?(_user_id)
        true
      end
    end
  end
end
