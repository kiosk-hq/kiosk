# frozen_string_literal: true

require "kiosk/agent_identity_providers/base"

module Kiosk
  module Server
    module AgentIdentityProviders
      # Bundled agent-IdP: verifies/issues RS256 JWTs against the provider's
      # own signing key; resolves agent payment keys from kiosk.agents.
      class DefaultAgentIdp < Kiosk::AgentIdentityProviders::Base
        def verify(request)
          header = authorization_for(request)
          return nil if header.nil? || header.empty?

          token  = header.sub(/\ABearer\s+/i, "")
          config = Kiosk.configuration
          claims = JwtIssuer.verify(
            token:    token,
            jwks:     Jwks.build(keys: [config.signing_key]),
            audience: Kiosk.current_issuer,
            issuer:   Kiosk.current_issuer,
          )
          Kiosk::Identity.new(
            user_id:  claims[:sub], role: claims[:role], actor: "agent",
            agent_id: claims[:agent_id], claims: claims,
          )
        rescue JwtIssuer::Error
          # Expired, revoked, wrongly-signed, or malformed tokens resolve to
          # nil — the controller turns nil into 401 Unauthenticated. Letting
          # the error escape here surfaced as an HTTP 500.
          nil
        end

        def issue(agent_id:, role:)
          claims = { sub: lookup_user_id(agent_id), agent_id: agent_id, actor: "agent" }
          # Role-less principals get NO role claim — an empty-string
          # claim would round-trip into an unusable Identity.
          claims[:role] = role.to_s unless role.nil? || role.to_s.empty?
          JwtIssuer.issue(
            claims: claims, audience: Kiosk.current_issuer, now: mint_instant(agent_id),
          )
        end

        def agent_payment_key(agent_id)
          pem = agents_column("public_key", agent_id)&.fetch("public_key", nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          OpenSSL::PKey::RSA.new(pem)
        end

        private

        # THE MINT INSTANT — never earlier than the agent's revocation
        # watermark, so this IdP can never hand out a token that is already
        # revoked.
        #
        # JWT timestamps are second-resolution and {RevocationStore} compares
        # `iat < watermark`, so "revoke everything for this agent" and "mint a
        # token for this agent" collide inside one wall-clock second. NEITHER
        # of the two obvious resolutions of that collision is correct on its
        # own:
        #
        #   * a watermark of `Time.now.to_i` leaves every token minted in that
        #     second verifying — which is the aperture §6.3's MUST forbids on
        #     the claim rebind, measured 3/3 on a booted demo;
        #   * a watermark of `Time.now.to_i + 1` closes it, but then kills the
        #     NEXT token too, and `/auth/login` in that same second is the
        #     recovery path §6.3 itself names ("or by re-running /auth/login").
        #     `kiosk-demo-tudu/test/wire/link_test.rb` walks exactly that sequence.
        #
        # Clamping here resolves both at once and puts the invariant in ONE
        # place instead of asking each caller to reason about it: a caller
        # revoking against a key stamps the whole second (`+1`), and any token
        # minted afterwards — the rebind's own replacement, a later
        # `/auth/login` — is simply dated at the watermark and survives. A
        # clamped token is at most one second ahead: inside the verifier's ±60s
        # leeway, its lifetime unchanged (`exp` moves with `iat`), and these
        # tokens are verified only by the origin that issued them.
        #
        # `/auth/revoke` is untouched: it stamps the CURRENT second, which is
        # never greater than now, so nothing is clamped and the strict `<`
        # keeps its replacement alive exactly as before.
        #
        # STORE CONTRACT: an operator-supplied `revocation_store` that does not
        # implement `watermark_for` mints at the unclamped instant rather than
        # crashing at token issuance — the reader is part of the documented
        # interface (see {RevocationStore}), and a store missing it re-opens
        # this one-second aperture for its own deployment.
        def mint_instant(agent_id)
          now   = Time.now
          store = Kiosk.configuration.revocation_store
          return now unless store.respond_to?(:watermark_for)

          watermark = store.watermark_for(agent_id)
          return now if watermark.nil? || watermark <= now.to_i

          Time.at(watermark)
        end

        def lookup_user_id(agent_id)
          row = agents_column("user_id", agent_id)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "unknown agent #{agent_id}" if row.nil?

          row.fetch("user_id")
        end

        # ONE live-agent lookup for both single-column callers. Separate
        # copies of the same statement would be more places to get the
        # identifier/value split below wrong.
        #
        # `column` is an IDENTIFIER chosen from the literals above — never
        # an argument, never caller-reachable — and Postgres cannot bind an
        # identifier anyway. `agent_id` is a VALUE and travels as `$1`. It comes
        # off a verified JWT claim or a row this engine wrote, so it is not
        # attacker-reachable either way; it binds because "safe today because of
        # who calls it" is not a guarantee this gem is willing to ship.
        #
        # `lease_connection`, not `connection`: `ActiveRecord::Base.connection`
        # is soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`, and this IdP is on the
        # path of every authenticated request there is. `with_connection` is not
        # used because `agent_payment_key` is called from inside the pay path's
        # open transaction, where the mandate rows being verified live.
        def agents_column(column, agent_id)
          ::ActiveRecord::Base.lease_connection.exec_query(
            "SELECT #{column} FROM #{schema}.agents WHERE id = $1 AND revoked_at IS NULL",
            "Kiosk agent #{column}",
            [agent_id],
          ).to_a.first
        end

        def schema = Kiosk.configuration.schema

        def authorization_for(request)
          if request.respond_to?(:headers)
            request.headers["Authorization"] || request.headers["authorization"]
          elsif request.is_a?(Hash)
            request["HTTP_AUTHORIZATION"]
          end
        end
      end
    end
  end
end
