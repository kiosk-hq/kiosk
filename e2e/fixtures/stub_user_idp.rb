# frozen_string_literal: true

# Stub user-IdP for the e2e demo — the "provider's own web session" channel
# (in production: a real adapter such as kiosk-user-idp-devise reading the
# Warden user). Parses `Authorization: user:u-<uuid>` into a
# {Kiosk::Identity} with actor=user. The account-binding pages (device
# verify, link mint, unlink) authenticate the approving human through this
# channel; agents never present this shape.
class StubUserIdp < Kiosk::AgentIdentityProviders::Base
  USER_RE = /\Auser:u-(?<user_id>[0-9a-fA-F-]+)\z/

  def verify(request)
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
