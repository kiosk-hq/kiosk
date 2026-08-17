# frozen_string_literal: true

module Kiosk
  module Server
    # The product of the account-binding ceremony: a durable
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
    #     trust). When the ceremony carries a `requested_role` (roles-from-
    #     IdP, Path A: the new human's role), `allowed_roles` is REMAPPED to
    #     it — the agent adopts the role of the principal it is now bound to,
    #     the same "adopt the new principal's context" rule reputation-carry
    #     follows; a role-less ceremony leaves `allowed_roles` untouched. The
    #     `assistant_claimed` hook then lets the vertical migrate domain data
    #     (core never touches provider rows) — but ONLY when the holder
    #     actually changed: re-binding a key to the human it is already bound
    #     to transitions nothing and fires no hook (K-783).
    #
    # Tokens are ALWAYS minted through the same {AgentIdentityProviders::
    # DefaultAgentIdp}/{JwtIssuer} path as `/auth/login` — the ceremony is
    # a binding surface, never a second token story.
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
          rebind(conn, config, existing, user_id, requested_role)
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

        # Known key: remap the principal, keep agent_id + reputation. The
        # hook runs inside the transaction so a raising provider migration
        # rolls the rebind back atomically. Because the principal changes, the
        # key's pre-link tokens are watermark-revoked (like `unlink!`) — only
        # the freshly minted token below survives.
        #
        # Role on rebind (roles-from-IdP, Path A): when the ceremony carries a
        # `requested_role` (the NEW human's role, validated against
        # `config.roles`), `allowed_roles` is REMAPPED to it in the same
        # UPDATE — the agent adopts the role of the principal it is now bound
        # to. A role-less ceremony (`requested_role` nil) leaves the existing
        # `allowed_roles` untouched, so single-role / no-IdP providers keep
        # today's behavior with no regression.
        def rebind(conn, config, existing, user_id, requested_role = nil)
          agent_id = existing.fetch("id")
          previous = existing.fetch("user_id")
          new_role = validated_role(config, requested_role)
          # nil requested_role → keep the agent's own registered role.
          effective_role = new_role || primary_role(existing.fetch("allowed_roles"))

          # A re-bind to the SAME principal transitions nothing, so the hook
          # does not fire (K-783). `assistant_claimed` is a NOTIFICATION —
          # "this key's holder changed from A to B, migrate A's domain rows to
          # B" — and every host that acts on it is entitled to believe it. Call
          # it with `previous_user_id == user_id` and the host is being told a
          # migration is due when there is nothing to migrate: tudu's hook, the
          # only one in the fleet, then found the human already a member of all
          # her own lists, moved nothing, and ran its "drop the now-redundant
          # HEADLESS memberships" DELETE against her own rows — deleting every
          # membership she had while leaving her owning the lists.
          #
          # The engine cannot fix that in the host: a hook is the operator's
          # code, and a no-op transition is not a thing an operator should have
          # to defend against. So the guard is here, at the one place that knows
          # whether a transition happened.
          #
          # ONLY the hook is skipped. The UPDATE still runs (it carries the
          # roles-from-IdP `allowed_roles` remap — re-binding a key to the same
          # human under a NEW role is a real change, and a blanket no-op on
          # `bind!` would silently drop it), and the watermark revocation +
          # fresh token still happen, so nothing an assistant can observe on the
          # wire moved. Whether an idempotent re-bind SHOULD still revoke is
          # spec-silent and left to Phil — K-787.
          transition = previous.to_s != user_id.to_s
          conn.transaction do
            role_set = new_role ? ", allowed_roles = ARRAY[#{conn.quote(new_role)}]::text[]" : ""
            conn.execute(<<~SQL)
              UPDATE #{config.schema}.agents
              SET user_id = #{conn.quote(user_id)}#{role_set}
              WHERE id = #{conn.quote(agent_id)}
            SQL
            if transition
              config.assistant_claimed&.call(
                agent: agent_id, previous_user_id: previous, user_id: user_id,
              )
            end
          end

          # A rebind is a principal change: the key's pre-link tokens still
          # carried the OLD `sub`, so they must die exactly as `unlink!` does —
          # "linking makes the agent re-login" holds literally. Same watermark
          # `/auth/revoke` and `unlink!` use: every token minted strictly BEFORE
          # this instant stops verifying; the replacement token minted just below
          # (and any later `/auth/login`) is issued at/after the watermark and
          # survives the store's strict `iat < watermark` check.
          config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i)

          token = issue_token(agent_id, effective_role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: false }
        end

        # Fresh key: a new linked assistant account under the approving
        # human's principal. Role: the ceremony's requested_role (the bound
        # human's role under roles-from-IdP, validated against the provider's
        # declared roles) or the provider's registration_role default; NULL
        # when neither is set (roles are hook-or-absent).
        def register_linked(conn, config, pem, user_id, requested_role)
          role = validated_role(config, requested_role || config.registration_role)

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

        # Normalise a candidate role to a String (or nil when absent/blank)
        # and reject any value outside the provider's declared `config.roles`.
        # Shared by fresh-key registration and rebind so both apply the same
        # gate — an agent (or a leaked link row) can never widen its scope
        # past a role the provider actually declares.
        def validated_role(config, candidate)
          role = candidate&.to_s
          role = nil if role && role.empty?
          if role && !config.roles.map(&:to_s).include?(role)
            raise Errors::ConfigurationError,
                  "binding role #{role.inspect} is not among configured roles #{config.roles.inspect}"
          end
          role
        end

        # kiosk-pop is the only token minter: same
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
