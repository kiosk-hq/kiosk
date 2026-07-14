# frozen_string_literal: true

# Stub Agent-IdP for this demo app. Parses `Authorization: Bearer …` into
# a {Kiosk::Identity}. Real adapters (Devise / Auth0 / WorkOS / etc.) ship
# as `kiosk-user-idp-*` and `kiosk-agent-idp-*` gems.
#
# One token shape:
#
#   agent:u-<uuid>:a-<agent_id>:r-<role>   → identity with actor=agent
#
# Anything else returns nil → WireController treats as unauthenticated.
class StubIdp < Kiosk::AgentIdentityProviders::Base
  AGENT_RE = /\A
    agent:
    u-(?<user_id>[0-9a-fA-F-]+):
    a-(?<agent_id>[^:]+):
    r-(?<role>\w+)\z
  /x.freeze

  def verify(request)
    header = authorization_for(request)
    return nil if header.nil? || header.empty?

    token = header.sub(/\ABearer\s+/, "")

    if (match = AGENT_RE.match(token))
      Kiosk::Identity.new(
        user_id:  match[:user_id],
        agent_id: match[:agent_id],
        role:     match[:role],
        actor:    "agent",
      )
    end
  end

  private

  def authorization_for(request)
    if request.respond_to?(:headers)
      request.headers["Authorization"] || request.headers["authorization"]
    elsif request.is_a?(Hash)
      request["HTTP_AUTHORIZATION"] || request[:authorization]
    elsif request.is_a?(String)
      request
    end
  end
end
