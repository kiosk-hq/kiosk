# frozen_string_literal: true

# Composite Agent-IdP for this demo app: tries Kiosk-issued JWTs first (minted
# by the bundled kiosk-pop IdP via register/login; the OAuth device-grant
# surface is dormant), falls back to the bespoke
# `agent:u-…:a-…:r-…` shape that StubIdp parses.
# Lets the whole wire surface (the per-verb endpoints /kiosk/<verb-name> plus
# the reserved /kiosk/schema and /kiosk/pay) authenticate both legacy synthetic
# tokens AND real kiosk-pop-issued JWTs in the same run.
#
# In production, a host app would pick ONE of these (or a real adapter
# like kiosk-user-idp-devise). The composite shape is a demo convenience,
# not part of any shipped gem.
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

    # SECURITY (K-539): the cleartext `agent:u-…:a-…:r-…` stub fallback is a
    # dev/test convenience ONLY — StubIdp authenticates an UNSIGNED, self-asserted
    # identity at ANY role (incl. owner). In production it MUST be unreachable: an
    # external agent registers via PoW→kiosk-pop and presents the SIGNED JWT
    # handled above. This guard is load-bearing — even if an initializer wires a
    # stub in production, a forged bearer is rejected here (verify → nil → wire 401).
    return nil unless Rails.env.local? && @stub

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
