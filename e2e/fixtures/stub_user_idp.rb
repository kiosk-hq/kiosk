# frozen_string_literal: true

# Stub user-IdP for the e2e demo — the "provider's own web session" channel
# (in production: a real adapter such as kiosk-user-idp-devise reading the
# Warden user). Parses `Authorization: user:u-<uuid>` into a
# {Kiosk::Identity} with actor=user. The account-binding pages (device
# verify, link mint, unlink) authenticate the approving human through this
# channel; agents never present this shape.
#
# DEV/TEST ONLY (K-555): this parses an UNSIGNED, self-asserted
# `user:u-<uuid>` bearer into a HUMAN {Kiosk::Identity} with NO signature —
# on the wire anyone could impersonate any human. Gated to Rails.env.local?
# in #verify AND at the initializer (`c.user_idp` is nil in production). The
# e2e harness boots in development, so the guard passes here. Never reachable
# in production. Sibling of the K-539 agent-stub fix.
class StubUserIdp < Kiosk::AgentIdentityProviders::Base
  USER_RE = /\Auser:u-(?<user_id>[0-9a-fA-F-]+)\z/

  def verify(request)
    # SECURITY (K-555): DEV/TEST ONLY. Un-signed self-asserted human bearer —
    # gated to Rails.env.local? (the e2e harness runs in development, so this
    # passes) and to the initializer wiring. See the demos' stub_user_idp.rb.
    return nil unless Rails.env.local?

    header = authorization_for(request)
    return nil if header.nil? || header.empty?

    token = header.sub(/\ABearer\s+/, "")
    if (match = USER_RE.match(token))
      Kiosk::Identity.new(
        user_id:  match[:user_id],
        agent_id: nil,
        role:     "customer",
        actor:    "human",
      )
    end
  end

  private

  def authorization_for(request)
    request.headers["Authorization"] || request.headers["authorization"]
  end
end
