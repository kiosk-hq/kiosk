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
    #     ceremony can carry), `allowed_roles` is REMAPPED to
    #     it — the agent adopts the role of the principal it is now bound to,
    #     the same "adopt the new principal's context" rule reputation-carry
    #     follows; a role-less ceremony remaps it to the operator's
    #     `registration_role`, exactly as a fresh key would land. The
    #     `assistant_claimed` hook then lets the vertical migrate domain data
    #     (core never touches provider rows) — but ONLY when the holder
    #     actually changed: re-binding a key to the human it is already bound
    #     to transitions nothing and fires no hook.
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
      # `requested_role:` IS NEVER A CLIENT'S ROLE, on either ceremony. Both
      # callers read it off the row, and both rows got it from a HUMAN's
      # `Identity#role`: the link row at mint ({LinkCode.mint}, over
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

        warn_role_resolution_not_total(config, requested_role)

        # `lease_connection`, not `connection` (following
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
          SELECT id, user_id FROM #{config.schema}.agents
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
        # The watermark is stamped at the NEXT second, not this one.
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
        # Role on rebind (roles-from-IdP, Path A): `allowed_roles` is REMAPPED
        # in the same UPDATE, always, to whatever {.resolved_role} answers —
        # the ceremony's role when it carries one (the NEW human's, validated
        # against `config.roles`), else the operator's `registration_role`,
        # else the empty set. The agent adopts the role of the principal it is
        # now bound to, and the role the key arrived with is not an input:
        # it belonged to the principal the key is leaving.
        #
        # THAT IS WHY THE ROW IS NEVER READ FOR ITS ROLE. Resolve from the
        # agent's own `allowed_roles` instead and an agent already carrying the
        # privileged role, rebound to a human who holds none, keeps the
        # privilege while `sub` becomes that human's — the engine would be
        # deciding a privilege from a principal that is no longer there.
        # There is always a default role, and never a nil.
        def rebind(conn, config, existing, user_id, requested_role = nil)
          agent_id = existing.fetch("id")
          previous = existing.fetch("user_id")
          role     = resolved_role(config, requested_role)

          # A re-bind to the SAME principal transitions nothing, so the hook
          # does not fire. `assistant_claimed` is a NOTIFICATION —
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
          # wire moved. That an idempotent re-bind STILL revokes is normative:
          # protocol.md §6.3 says so, and says the response is
          # indistinguishable from any other rebind's.
          transition = previous.to_s != user_id.to_s
          # "No role" is a STATEMENT SHAPE, not a value (the same distinction
          # `executor.rb#settled_total_cents` draws about its window, and the
          # same split `register_linked` makes below): the empty array cannot
          # travel as a bind, so THAT stays a branch on the text while a role
          # itself is `$3`. Either way the column is assigned — the old row's
          # value never survives a rebind.
          role_set, role_binds =
            role ? [", allowed_roles = ARRAY[$3]::text[]", [role]] : [", allowed_roles = '{}'::text[]", []]
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
          # The watermark is the NEXT second, not this one. JWT timestamps are
          # second-resolution and the store's comparison is a strict
          # `iat < watermark`, so a watermark of `Time.now.to_i` leaves EVERY
          # pre-link token minted in the same wall-clock second verifying for
          # its full remaining lifetime —
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

          token = issue_token(agent_id, role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: false }
        end

        # Fresh key: a new linked assistant account under the approving
        # human's principal. Role: whatever {.resolved_role} answers, the same
        # call the rebind branch makes.
        def register_linked(conn, config, pem, user_id, requested_role)
          role = resolved_role(config, requested_role)

          # `'{}'::text[]` is a statement shape (no role at all),
          # `ARRAY[$3]::text[]` a bound value — same split as the rebind UPDATE
          # above. The empty array and NOT `NULL` for the reason spelled out on
          # `agent_registration.rb`'s copy of this branch: the column is
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

        # THE ROLE A BINDING LANDS ON, and the ONE place either branch asks.
        # The ceremony's role when it carries one, else the operator's
        # configured default, else the empty role set for an operator that
        # assigns roles to nobody. Never the role the key is already carrying:
        # that one was the previous principal's, and a binding whose whole
        # product is a human's consent may not hand out a privilege resolved
        # from somebody else's account.
        #
        # Fresh key and rebind share the call rather than each spelling it,
        # because they disagreeing is precisely the defect this closes: the
        # rebind branch used to fall back to the agent's own `allowed_roles`,
        # so the one path on which a role can NARROW would otherwise be the one
        # path that did not reach for the configured default.
        def resolved_role(config, requested_role)
          validated_role(config, requested_role || config.registration_role)
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

        # ROLE RESOLUTION IS TOTAL, OR THE OPERATOR HAS NO ROLES. An operator
        # that declares roles at all owes one to EVERY human who can approve a
        # binding; a role for staff and nothing for customers is a
        # MISCONFIGURATION of the operator's identity system, not a case the
        # ceremony has to define. kiosk.tech `protocol.md` §6.3 and
        # `specification.html` state the contract.
        #
        # WHY THIS WARNS INSTEAD OF CRASHING AT BOOT — AND WHAT DOES CRASH
        # THERE. The contract has two halves and they are decidable in
        # different places. The CONFIGURATION half — that an origin declaring a
        # role vocabulary also configures a default to fall back to — is two
        # settings in the operator's own initializer, and the engine refuses to
        # start without it ({Engine.default_role_configuration_error}). That is
        # why `config.registration_role` is known to be a declared role by the
        # time this method runs at all.
        #
        # The half LEFT is not that fact. It is a property of the host's
        # `#kiosk_role` over every row in the host's users table, and nothing
        # in the initializer, the schema or the adapter can decide it — an
        # origin declaring two roles and defining `#kiosk_role` is the CORRECT
        # multi-role shape, so a boot check THERE would either accuse every such
        # origin or catch nothing. The one moment it IS decidable with
        # certainty is this one: a ceremony arriving with no role at an origin
        # that declares more than one is the unsupported mixture and nothing
        # else, because a single-role origin cannot exhibit it (its default IS
        # its only role) and a role-less origin has nothing to resolve.
        #
        # WHAT IT IS NOT. It is not a stand-in for a fix: the ceremony does
        # nothing surprising with a role it cannot resolve — it applies the
        # operator's configured default exactly as registration would. What the
        # operator still cannot see without this line is the OTHER direction —
        # a member of staff whose identity system answers nothing gets an
        # assistant at the customer default, quietly, and every privileged verb
        # then reads as if they had no standing. That is worth one line per
        # ceremony rather than one at boot: a misconfiguration that shows up
        # once and never again is one nobody reads.
        def warn_role_resolution_not_total(config, requested_role)
          return unless requested_role.nil? || requested_role.to_s.strip.empty?
          return unless config.roles.to_a.size > 1

          # An origin reaching this line always HAS a default role: a declared
          # vocabulary with none is refused at boot, so there is no second
          # landing to describe and no branch here.
          landing =
            "this binding lands on #{config.registration_role.inspect}, the role " \
            "registration would assign"
          message =
            "[kiosk-server] an account-binding ceremony resolved NO role for the approving " \
            "human, and this origin declares more than one role " \
            "(#{config.roles.inspect}). Role resolution must be TOTAL: an operator that " \
            "assigns roles at all assigns one to EVERY human who can approve a binding. A " \
            "role for staff and nothing for customers is not a supported configuration — " \
            "#{landing}, so a human who should hold a privileged one gets an assistant " \
            "that cannot act for them. Fix the identity system, not the ceremony: a " \
            "`#kiosk_role` that can answer nil is the usual cause, and returning the " \
            "least-privileged declared role instead makes it total."
          # Rails.logger is nil until the host app boots (rake tasks, console
          # helpers, the gem's own specs), so keep the Kernel#warn fallback —
          # same shape as {PopVerifier.log_audience_mismatch}.
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.warn(message) : Kernel.warn(message)
        end

        # kiosk-pop is the only token minter: same
        # DefaultAgentIdp path as /auth/login and /auth/register.
        def issue_token(agent_id, role)
          AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        end
      end
    end
  end
end
