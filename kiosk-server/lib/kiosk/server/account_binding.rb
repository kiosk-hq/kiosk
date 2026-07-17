# frozen_string_literal: true

module Kiosk
  module Server
    # The product of the account-binding ceremony (ADR-0017): a durable
    # «public key → assistant-account holder's user_id» link. Shared by the
    # claim flow (POST /oauth/token, device_code grant) and the link flow
    # (POST /auth/claim) — both call {.bind!} after their possession proof
    # (BIND-POP) has passed, so a binding can only ever attach a key the
    # caller demonstrably controls.
    #
    # Fresh vs known key — the ONLY difference between first contact and
    # the upgrade of an already-registered key:
    #
    #   - **Fresh key** → a new `kiosk.agents` row is registered as a
    #     linked assistant account under the approving human's `user_id`.
    #     No `assistant_creation` factory runs — the principal already
    #     exists.
    #   - **Known key** → **rebind**: `agent_id` stays stable,
    #     `agents.user_id` remaps to the human's, and the identity's
    #     reputation carries over untouched (no whitewash, no inherited
    #     trust). The `assistant_claimed` hook then lets the vertical
    #     migrate domain data (core never touches provider rows).
    #
    # Tokens are ALWAYS minted through the same {AgentIdentityProviders::
    # DefaultAgentIdp}/{JwtIssuer} path as `/auth/login` — the ceremony is
    # a binding surface, never a second token story (ADR-0008 holds).
    module AccountBinding
      module_function

      # Create or remap the key→account binding and mint a standard
      # kiosk-pop access token for it. Call ONLY after possession of
      # `public_key_pem` has been proven (BIND-POP).
      #
      # @return [Hash] { agent_id:, user_id:, access_token:, fresh: }
      def bind!(public_key_pem:, user_id:, requested_role: nil)
        config = Kiosk.configuration
        pem    = public_key_pem.to_s.strip
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        conn = ActiveRecord::Base.connection
        existing = conn.execute(<<~SQL).first
          SELECT id, user_id, allowed_roles FROM #{config.schema}.agents
          WHERE public_key = #{conn.quote(pem)} AND revoked_at IS NULL
          LIMIT 1
        SQL

        if existing
          rebind(conn, config, existing, user_id)
        else
          register_linked(conn, config, pem, user_id, requested_role)
        end
      end

      # Registration-layer revocation (auth.md's second layer): deactivate
      # the binding of `agent_id` — which must belong to `user_id`, so a
      # session can only unlink its OWN assistant accounts. The key's
      # outstanding tokens stop verifying (watermark revocation) and its
      # `/auth/login` is denied (`revoked_at` filter). An unlinked key does
      # NOT revert to a standalone account — re-register or re-claim to
      # return. Fires the `assistant_unlinked` hook.
      #
      # @raise [Errors::NotFound] when no live agent row matches the pair.
      def unlink!(agent_id:, user_id:)
        config = Kiosk.configuration
        raise Errors::BadRequest.new("agent_id required") if agent_id.nil? || agent_id.to_s.empty?

        conn = ActiveRecord::Base.connection
        row = conn.execute(<<~SQL).first
          UPDATE #{config.schema}.agents
          SET revoked_at = now()
          WHERE id = #{conn.quote(agent_id)}
            AND user_id = #{conn.quote(user_id)}
            AND revoked_at IS NULL
          RETURNING id
        SQL
        if row.nil?
          raise Errors::NotFound.new(
            "no linked assistant account with this agent_id",
            hint: "only assistant accounts bound to the signed-in account can be unlinked",
          )
        end

        # Outstanding tokens die NOW, not at their natural expiry — the
        # same watermark `/auth/revoke` uses.
        config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i)
        config.assistant_unlinked&.call(agent: agent_id, user_id: user_id)
        { agent_id: agent_id }
      end

      class << self
        private

        # Known key: remap the principal, keep agent_id + allowed_roles +
        # reputation. The hook runs inside the transaction so a raising
        # provider migration rolls the rebind back atomically.
        def rebind(conn, config, existing, user_id)
          agent_id = existing.fetch("id")
          previous = existing.fetch("user_id")

          conn.transaction do
            conn.execute(<<~SQL)
              UPDATE #{config.schema}.agents
              SET user_id = #{conn.quote(user_id)}
              WHERE id = #{conn.quote(agent_id)}
            SQL
            config.assistant_claimed&.call(
              agent: agent_id, previous_user_id: previous, user_id: user_id,
            )
          end

          token = issue_token(agent_id, primary_role(existing.fetch("allowed_roles")))
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: false }
        end

        # Fresh key: a new linked assistant account under the approving
        # human's principal. Role: the ceremony's requested_role (validated
        # against the provider's declared roles at request time) or the
        # provider's registration_role default; NULL when neither is set
        # (ADR-0011: roles are hook-or-absent).
        def register_linked(conn, config, pem, user_id, requested_role)
          role = (requested_role || config.registration_role)&.to_s
          role = nil if role && role.empty?
          if role && !config.roles.map(&:to_s).include?(role)
            raise Errors::ConfigurationError,
                  "binding role #{role.inspect} is not among configured roles #{config.roles.inspect}"
          end

          allowed_roles_sql = role ? "ARRAY[#{conn.quote(role)}]::text[]" : "NULL"
          agent_id = conn.transaction do
            conn.execute(<<~SQL).first.fetch("id")
              INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key)
              VALUES (#{conn.quote(user_id)}, #{allowed_roles_sql}, #{conn.quote(pem)})
              RETURNING id
            SQL
          end

          token = issue_token(agent_id, role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: true }
        end

        # kiosk-pop is the only token minter (ADR-0008/0017): same
        # DefaultAgentIdp path as /auth/login and /auth/register.
        def issue_token(agent_id, role)
          AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        end

        # `allowed_roles` comes back as a Postgres text[] literal
        # ("{customer}") or an Array depending on adapter casting — same
        # parsing as {AgentLogin}.
        def primary_role(allowed_roles)
          case allowed_roles
          when Array then allowed_roles.first
          else allowed_roles.to_s.delete("{}").split(",").first
          end
        end
      end
    end
  end
end
