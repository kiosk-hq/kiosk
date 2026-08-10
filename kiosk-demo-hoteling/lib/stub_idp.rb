# frozen_string_literal: true

# Stub Agent-IdP for this demo app. Parses `Authorization: Bearer …` into
# a {Kiosk::Identity}. The only real adapter shipped today is
# `kiosk-user-idp-devise` (a user-IdP, currently unwired). Third-party
# agent-IdP adapters (Entra / Okta / Passport-style) are planned to ship as
# `kiosk-agent-idp-*` gems — none exist yet.
#
# One token shape:
#
#   agent:u-<uuid>:a-<agent_id>:r-<role>   → identity with actor=agent
#
# Anything else returns nil → WireController treats as unauthenticated.
# DEV/TEST ONLY (K-539): authenticates UNSIGNED, self-asserted bearers at any
# role — gated to Rails.env.local? here and in JwtOrStubIdp. Never reachable in
# production, where auth flows through the signed kiosk-pop JWT.
class StubIdp < Kiosk::AgentIdentityProviders::Base
  AGENT_RE = /\A
    agent:
    u-(?<user_id>[0-9a-fA-F-]+):
    a-(?<agent_id>[^:]+):
    r-(?<role>\w+)\z
  /x.freeze

  def verify(request)
    # SECURITY (K-539): DEV/TEST ONLY. This parses an UNSIGNED, self-asserted
    # `agent:u-…:a-…:r-…` bearer into an identity at ANY role — a driver
    # convenience so demos can skip PoP registration. JwtOrStubIdp already gates
    # the fallback to Rails.env.local?; this second guard makes the dev-only
    # contract unmissable even if StubIdp is ever wired directly. Production auth
    # flows through the signed kiosk-pop JWT, never this parser.
    return nil unless Rails.env.local?

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
    # Sole caller is JwtOrStubIdp#verify, which forwards the Rails request.
    request.headers["Authorization"] || request.headers["authorization"]
  end
end
