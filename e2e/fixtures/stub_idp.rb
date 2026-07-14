# frozen_string_literal: true

# Stub Agent-IdP for the e2e demo. Parses `Authorization: Bearer …` into
# a {Kiosk::Identity}. The only real adapter shipped today is
# `kiosk-user-idp-devise` (a user-IdP, currently unwired). Third-party
# agent-IdP adapters (Entra / Okta / Passport-style) are planned to ship as
# `kiosk-agent-idp-*` gems — none exist yet.
#
# Token shape:
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
    # All callers pass a Rails request (see Base#verify @param [#headers, #env]).
    request.headers["Authorization"] || request.headers["authorization"]
  end
end
