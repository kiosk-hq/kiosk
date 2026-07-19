# frozen_string_literal: true

# Composite user-IdP for the demo: tries the role-carrying StubUserIdp first
# (the salon's SSO/Okta stand-in — an `X-Staff-Session` header naming a staff
# member), then falls back to the real Devise session (the binding
# walkthrough's /users/sign_in cookie). Lets demo:roles (staff, role-carrying
# session) and demo:binding (a customer's real Devise session) share ONE
# `c.user_idp` wiring.
#
# In production a provider picks ONE user-IdP adapter; this composite is a
# convenience of the demo app, not part of the kiosk-server gem.
class CompositeUserIdp < Kiosk::UserIdentityProviders::Base
  def initialize(*idps)
    @idps = idps
  end

  def verify(request)
    @idps.each do |idp|
      identity = idp.verify(request)
      return identity if identity
    end
    nil
  end
end
