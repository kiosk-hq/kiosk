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
#
# DEV/TEST ONLY (K-555): this parses an UNSIGNED, self-asserted
# `user:u-<uuid>` bearer into a HUMAN {Kiosk::Identity} with NO signature —
# on the wire anyone could impersonate any human (cross-tenant read/write).
# Gated to Rails.env.local? in #verify AND at the initializer (`c.user_idp`
# is nil in production). Never reachable in production, where the human's
# session comes from a real adapter (kiosk-user-idp-devise). Sibling of the
# K-539 agent-stub fix.
class StubUserIdp < Kiosk::UserIdentityProviders::Base
  USER_RE = /\Auser:u-(?<user_id>[0-9a-fA-F-]+)\z/

  def verify(request)
    # SECURITY (K-555): DEV/TEST ONLY. This parses an UNSIGNED, self-asserted
    # `user:u-<uuid>` bearer into a HUMAN identity — a driver convenience so the
    # account-binding surfaces can be walked without a real provider login. The
    # initializer wires this stub only under Rails.env.local?; this second guard
    # is load-bearing — even if the stub is ever wired directly, a forged human
    # bearer is rejected here (verify → nil → the surface 401s). Production human
    # sessions flow through a real user_idp adapter, never this parser.
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
