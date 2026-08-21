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
            audience: config.issuer,
            issuer:   config.issuer,
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
            claims: claims, audience: Kiosk.configuration.issuer, now: mint_instant(agent_id),
          )
        end

        def agent_payment_key(agent_id)
          pem = agents_column("public_key", agent_id)&.fetch("public_key", nil)
          raise Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent #{agent_id}" if pem.nil?

          OpenSSL::PKey::RSA.new(pem)
        end

        # Returns true iff the agent has a non-NULL `kyc_verified_at` timestamp.
        # The binary KYC gate. A KYC-restricted Action (e.g. skooti's
        # `rent_motorcycle`) calls this, or the finer-grained
        # {#kyc_has_attributes?} when it needs specific booleans.
        def kyc_verified?(agent_id)
          row = agents_column("kyc_verified_at", agent_id)
          return false if row.nil?

          !row.fetch("kyc_verified_at", nil).nil?
        end

        # Returns the NAMED ANONYMIZED boolean attributes a valid attestation
        # granted this agent — a String-keyed hash like
        # `{"age_over_18" => true, "licence_a" => true}`. Empty `{}` when the
        # agent verified with a bare binary attestation, or when no attestation
        # is on file / the agent is unknown or revoked. Only the NAMES were ever
        # stored — never the DOB, licence number, or any document (the
        # anonymized point).
        #
        # Since K-656/T-061 the grants live in `<schema>.kyc_attributes`, one
        # ROW per granted name, rather than in a jsonb column — so there is no
        # stored value to parse and no spelling of `true` for this method to
        # adjudicate. Every returned value is the Ruby `true` this method
        # synthesises from the row's EXISTENCE, which is what makes a caller's
        # `== true` (see {#kyc_has_attributes?}) safe rather than lucky.
        #
        # The join to `agents` is what keeps a REVOKED agent answering `{}`: the
        # rows survive revocation (the agent row does), and a gate must not.
        def kyc_attributes(agent_id)
          rows = ::ActiveRecord::Base.lease_connection.exec_query(
            "SELECT k.name FROM #{schema}.kyc_attributes k " \
            "JOIN #{schema}.agents a ON a.id = k.agent_id " \
            "WHERE k.agent_id = $1 AND a.revoked_at IS NULL",
            "Kiosk agent kyc attributes",
            [agent_id],
          )
          rows.to_a.each_with_object({}) { |row, acc| acc[row["name"]] = true }
        end

        # Returns true iff EVERY name in `required` is present-and-true in the
        # agent's stored KYC attributes. `required` is a list of attribute
        # names (Strings/Symbols). Used by an attribute-gated Action, e.g.
        # `rent_motorcycle` requiring both `age_over_18` and `licence_a`.
        def kyc_has_attributes?(agent_id, required)
          attrs = kyc_attributes(agent_id)
          Array(required).all? { |name| attrs[name.to_s] == true }
        end

        private

        # THE MINT INSTANT — never earlier than the agent's revocation
        # watermark, so this IdP can never hand out a token that is already
        # revoked (K-836).
        #
        # JWT timestamps are second-resolution and {RevocationStore} compares
        # `iat < watermark`, so "revoke everything for this agent" and "mint a
        # token for this agent" collide inside one wall-clock second. Both
        # resolutions of that collision used to be wrong somewhere:
        #
        #   * a watermark of `Time.now.to_i` leaves every token minted in that
        #     second verifying — which is the aperture §6.3's MUST forbids on
        #     the claim rebind, measured 3/3 on a booted demo;
        #   * a watermark of `Time.now.to_i + 1` closes it, but then kills the
        #     NEXT token too, and `/auth/login` in that same second is the
        #     recovery path §6.3 itself names ("or by re-running /auth/login").
        #     `kiosk-demo-tudu/script/link_flow.rb` walks exactly that sequence.
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
        # implement `watermark_for` keeps the old behaviour rather than
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

        # ONE live-agent lookup for all three single-column callers (K-782).
        # Four copies of the same statement were four places to forget a
        # `quote`; the private `def quote` that fed them is gone with them.
        # ({#kyc_attributes} is the fourth reader and no longer one of them —
        # since K-656 it reads a TABLE, not a column on this row.)
        #
        # `column` is an IDENTIFIER chosen from the three literals above — never
        # an argument, never caller-reachable — and Postgres cannot bind an
        # identifier anyway. `agent_id` is a VALUE and travels as `$1`. It comes
        # off a verified JWT claim or a row this engine wrote, so it was not
        # attacker-reachable before either; it binds because "safe today because
        # of who calls it" is what this row exists to stop shipping.
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
