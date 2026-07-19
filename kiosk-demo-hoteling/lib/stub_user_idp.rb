# frozen_string_literal: true

# Stub user-IdP for this demo app — the "provider's own web session"
# channel. This demo ships no human login UI, so the account-binding
# surfaces (device verify page, link mint, unlink) authenticate the
# approving human through this stub instead: `Authorization: user:u-<uuid>`
# parses into a {Kiosk::Identity} with actor=human. In production this is
# a real session adapter — the only one shipped today is
# kiosk-user-idp-devise, which reads the request's Warden user (see
# kiosk-demo-stylish for it wired end-to-end). Agents never present
# this shape.
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
