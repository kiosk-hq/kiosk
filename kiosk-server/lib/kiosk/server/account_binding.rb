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
    #     IdP, Path A: the NEW human's own role, which is the only role either
    #     ceremony can carry — K-072), `allowed_roles` is REMAPPED to
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
      # `requested_role:` IS NEVER A CLIENT'S ROLE, on either ceremony
      # (K-072). Both callers read it off the row, and both rows got it from
      # a HUMAN's `Identity#role`: the link row at mint ({LinkCode.mint}, over
      # the minting session), the claim row at approval
      # ({DeviceVerification.approve}, over the approving session). The
      # `config.roles` membership check in {.validated_role} below is a
      # backstop against a provider whose `user_idp` returns something it
      # never declared — not the gate that keeps an assistant from choosing,
      # which is the absence of any wire parameter feeding this.
      #
      # @return [Hash] { agent_id:, user_id:, access_token:, fresh: }
      def bind!(public_key_pem:, user_id:, requested_role: nil)
        config = Kiosk.configuration
        pem    = public_key_pem.to_s.strip
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`. Not `with_connection`
        # either — `rebind` and `register_linked` open a transaction on this
        # object and run the operator's `assistant_claimed` /
        # `assistant_creation` hook inside it, and those hooks reach the
        # database through the host's own models. All of it has to land on the
        # ONE connection the request holds, or "a raising hook rolls the
        # binding back atomically" stops being true.
        conn = ::ActiveRecord::Base.lease_connection
        # The presented key is CALLER-SUPPLIED (the wire body's `public_key`,
        # or the device-authorization row the caller populated), so it travels
        # as a bind and never as SQL text.
        existing = conn.exec_query(<<~SQL, "Kiosk agent lookup by key", [pem]).to_a.first
          SELECT id, user_id, allowed_roles FROM #{config.schema}.agents
          WHERE public_key = $1 AND revoked_at IS NULL
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
      # outstanding tokens stop verifying (watermark revocation — every one of
      # them, including one minted in the same wall-clock second; see the
      # stamp below) and its `/auth/login` is denied (`revoked_at` filter).
      # An unlinked key does
      # NOT revert to a standalone account — re-register or re-claim to
      # return. Fires the `assistant_unlinked` hook.
      #
      # @raise [Errors::NotFound] when no live agent row matches the pair.
      def unlink!(agent_id:, user_id:)
        config = Kiosk.configuration
        raise Errors::BadRequest.new("agent_id required") if agent_id.nil? || agent_id.to_s.empty?

        # `agent_id` is CALLER-SUPPLIED (the manage-page form field); `user_id`
        # comes off the authenticated session. Both are binds — the ownership
        # predicate is the security boundary here, so neither may be text.
        conn = ::ActiveRecord::Base.lease_connection
        row = conn.exec_query(<<~SQL, "Kiosk agent unlink", [agent_id, user_id]).to_a.first
          UPDATE #{config.schema}.agents
          SET revoked_at = now()
          WHERE id = $1
            AND user_id = $2
            AND revoked_at IS NULL
          RETURNING id
        SQL
        if row.nil?
          raise Errors::NotFound.new(
            "no linked assistant account with this agent_id",
            hint: "only assistant accounts bound to the signed-in account can be unlinked",
          )
        end

        # Outstanding tokens die NOW, not at their natural expiry.
        #
        # The watermark is stamped at the NEXT second, not this one (K-835).
        # {RevocationStore} compares `iat < watermark` and JWT timestamps are
        # second-resolution, so a watermark of `Time.now.to_i` leaves a token
        # minted in the SAME wall-clock second uncovered — and, because unlink
        # also 404s `/auth/login`, that token is then the LAST one the key will
        # ever hold and it keeps full access to the human's account for its
        # whole remaining lifetime (measured: 3600s). `/auth/revoke` can live
        # with that ambiguity because it hands the caller a replacement token
        # that must survive its own watermark; unlink returns no token, so it
        # has nothing to preserve and simply covers the whole second. That is
        # what makes spec §6.3 / §15.4 — "an unlinked key's tokens stop
        # verifying" — literally true rather than true-except-for-one-second.
        config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i + 1)
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
          # wire moved. That an idempotent re-bind STILL revokes is no longer
          # spec-silent: protocol.md §6.3 says so normatively, and says the
          # response is indistinguishable from any other rebind's (K-787).
          transition = previous.to_s != user_id.to_s
          # The role remap is a STATEMENT SHAPE, not a value (the same
          # distinction `executor.rb#settled_total_cents` draws about its
          # window): a role-less ceremony has no assignment at all, so THAT
          # stays a branch on the text while the role itself is `$3`.
          role_set, role_binds =
            new_role ? [", allowed_roles = ARRAY[$3]::text[]", [new_role]] : ["", []]
          conn.transaction do
            conn.exec_query(<<~SQL, "Kiosk agent rebind", [user_id, agent_id, *role_binds])
              UPDATE #{config.schema}.agents
              SET user_id = $1#{role_set}
              WHERE id = $2
            SQL
            if transition
              config.assistant_claimed&.call(
                agent: agent_id, previous_user_id: previous, user_id: user_id,
              )
            end
          end

          # A rebind is a principal change: the key's pre-link tokens still
          # carried the OLD `sub`, so they must die exactly as `unlink!` does —
          # "linking makes the agent re-login" holds literally, which is what
          # §6.3's MUST says.
          #
          # The watermark is the NEXT second, not this one (K-836, the residue
          # of K-835). JWT timestamps are second-resolution and the store's
          # comparison is a strict `iat < watermark`, so a watermark of
          # `Time.now.to_i` leaves EVERY pre-link token minted in the same
          # wall-clock second verifying for its full remaining lifetime —
          # measured 3/3 against a booted demo: a pre-link token whose `iat`
          # equals the rebind second still authenticated 200 afterwards.
          #
          # `unlink!` can simply pass `+1` because it returns no token. A rebind
          # DOES return one — and §6.3 also names `/auth/login` as the other way
          # back in, which an assistant may reach for in this very second
          # (`kiosk-demo-tudu/script/link_flow.rb` does exactly that). Both are
          # covered without a second rule here: the bundled IdP clamps every
          # mint to the agent's current watermark, so any token minted after
          # this line is dated AT the watermark and survives it — the
          # replacement below, and a later login alike. The invariant lives in
          # ONE place, {AgentIdentityProviders::DefaultAgentIdp#mint_instant},
          # rather than in each caller.
          config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i + 1)

          token = issue_token(agent_id, effective_role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: false }
        end

        # Fresh key: a new linked assistant account under the approving
        # human's principal. Role: the ceremony's requested_role (the bound
        # human's role under roles-from-IdP, validated against the provider's
        # declared roles) or the provider's registration_role default; the
        # EMPTY role set when neither is set (roles are hook-or-absent).
        def register_linked(conn, config, pem, user_id, requested_role)
          role = validated_role(config, requested_role || config.registration_role)

          # `'{}'::text[]` is a statement shape (no role at all),
          # `ARRAY[$3]::text[]` a bound value — same split as the rebind UPDATE
          # above. The empty array and NOT `NULL` for the reason spelled out on
          # `agent_registration.rb`'s copy of this branch (K-788): the column is
          # `NOT NULL`, so a literal NULL 500'd every fresh-key bind for a
          # provider that configures no role.
          allowed_roles_sql, role_binds =
            role ? ["ARRAY[$3]::text[]", [role]] : ["'{}'::text[]", []]
          sql = <<~SQL
            INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key)
            VALUES ($1, #{allowed_roles_sql}, $2)
            RETURNING id
          SQL
          agent_id = conn.transaction do
            conn.exec_query(sql, "Kiosk linked agent insert", [user_id, pem, *role_binds])
                .to_a.first.fetch("id")
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
