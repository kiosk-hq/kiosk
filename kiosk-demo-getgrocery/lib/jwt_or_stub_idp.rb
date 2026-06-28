# frozen_string_literal: true

# Composite IdP for the e2e: tries Kiosk-issued JWTs first (the
# Device-Grant flow output), falls back to the bespoke
# `agent:u-…:a-…:r-…` / `human:u-…:r-…` shape that StubIdp parses.
# Lets one /kiosk/exec endpoint authenticate both legacy synthetic
# tokens AND real OAuth-issued JWTs in the same test run.
#
# In production, a host app would pick ONE of these (or a real adapter
# like kiosk-user-idp-devise). The composite shape lives in the e2e
# fixture, not in the gem.
class JwtOrStubIdp < Kiosk::AgentIdentityProviders::Base
  def initialize(stub:)
    @stub = stub
  end

  def verify(request)
    bearer = bearer_token_for(request)
    if bearer && jwt_shaped?(bearer)
      identity = try_jwt(bearer)
      return identity if identity
    end
    @stub.verify(request)
  end

  private

  def bearer_token_for(request)
    header = if request.respond_to?(:headers)
               request.headers["Authorization"] || request.headers["authorization"]
             elsif request.is_a?(Hash)
               request["HTTP_AUTHORIZATION"]
             end
    return nil if header.nil? || header.empty?

    header.sub(/\ABearer\s+/i, "")
  end

  # JWT cheap-check: three dot-separated base64url segments.
  def jwt_shaped?(token)
    token.count(".") == 2
  end

  def try_jwt(token)
    claims = Kiosk::Server::JwtIssuer.verify(
      token:    token,
      jwks:     [Kiosk.configuration.signing_key],
      audience: Kiosk.configuration.issuer,
    )
    actor = (claims[:actor] || "human").to_s
    Kiosk::Identity.new(
      user_id:  claims[:sub],
      role:     claims[:role] || Kiosk.configuration.roles.first.to_s,
      actor:    actor,
      agent_id: (actor == "agent" ? claims[:agent_id] : nil),
      claims:   claims,
    )
  rescue Kiosk::Server::JwtIssuer::Error
    nil # let the stub IdP try its parse shape
  end
end
