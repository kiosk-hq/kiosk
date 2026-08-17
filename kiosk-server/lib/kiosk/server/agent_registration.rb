# frozen_string_literal: true

require "active_record"
require "active_support/core_ext/string/inflections" # String#constantize

module Kiosk
  module Server
    # Greenfield self-registration: provision the assistant account backing the
    # agent, bind an agent to it, then mint the agent's first token. No human.
    #
    # The assistant account is created either by a provider-supplied factory
    # (`config.assistant_creation`) or, when none is configured, by a
    # bare `user_model.create!` (the greenfield fallback — see #call).
    module AgentRegistration
      module_function

      def call(public_key_pem:, signed:, pow: nil)
        config = Kiosk.configuration
        role   = config.registration_role&.to_s
        role   = nil if role && role.empty?

        # The role is pinned server-side when configured — the agent never
        # sends one (that would be a privilege-selection primitive). OPTIONAL
        # (roles are hook-or-absent in 0.1): when unset, the agent
        # row gets NO role — an EMPTY `allowed_roles`, see the INSERT below —
        # and the provider may instead assign roles inside its
        # `assistant_creation` hook. A CONFIGURED role that is not among
        # the declared roles is still a provider error (loud 500).
        if role && !config.roles.map(&:to_s).include?(role)
          raise Errors::ConfigurationError,
                "registration_role #{role.inspect} is not among configured roles " \
                "#{config.roles.inspect}"
        end

        # Normalise PEM: coerce-to-String then strip leading/trailing whitespace
        # so lookup matches storage. `.to_s` first so a wrong-typed field (number,
        # object, array from the JSON body) yields a clean 400 downstream via
        # PopVerifier's invalid-key guard, not a NoMethodError 500 here.
        public_key_pem = public_key_pem.to_s.strip

        # Optional Equihash PoW to price fresh identity minting. No-op unless
        # the provider set registration_pow_count > 0. Raises 402 (with the
        # challenges) or 403 (bad-faith proof); one PoW, same wire as the
        # reputation gate.
        RegistrationPow.gate(public_key_pem: public_key_pem, pow: pow, config: config)

        # Prove the registrant controls the PRIVATE half of the key it is
        # registering — a public key alone is not a credential (it is public).
        # Origin-bound + single-use, so it can't be relayed or replayed.
        payload = PopVerifier.verify!(public_key_pem: public_key_pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: public_key_pem, nonce: payload.fetch(:nonce))

        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`. Not `with_connection`
        # either — the transaction below runs the operator's
        # `assistant_creation` factory, which persists through the host's own
        # models, and the factory's row and the agent row must land on the same
        # connection or they are not in the same transaction.
        conn = ::ActiveRecord::Base.lease_connection

        # A known public key is NOT re-registered — that would be a second way to
        # mint an identity for an existing key (and the old idempotent re-issue
        # blurred register vs. login). Existing keys refresh their token through
        # POST /auth/login instead.
        #
        # The key is CALLER-SUPPLIED — it is the request body — so it travels as
        # a bind, here and in the INSERT below.
        existing = conn.exec_query(<<~SQL, "Kiosk agent lookup by key", [public_key_pem]).to_a.first
          SELECT id FROM #{config.schema}.agents
          WHERE public_key = $1 AND revoked_at IS NULL
          LIMIT 1
        SQL
        if existing
          raise Errors::Conflict.new(
            "public key already registered",
            hint: "use POST /auth/login to refresh a token for an existing key",
          )
        end

        conn.transaction do
          # The principal backing this agent is an ASSISTANT ACCOUNT,
          # not necessarily a human user. Prefer the provider-supplied factory:
          # the provider creates its OWN record (satisfying its own model
          # validations) and RETURNS the principal id, which the framework uses
          # verbatim as `agents.user_id` — so it works for bigint AND uuid PKs.
          # Fall back to a bare `create!` only when no factory is configured —
          # that path 500s on any model with required attributes, which is
          # exactly why `assistant_creation` exists.
          assistant_account_id = create_assistant_account(config, public_key_pem)

          # No registration_role configured → the EMPTY SET of roles, written
          # explicitly. That is a statement SHAPE — there is no value to bind —
          # while the role itself, when there is one, is `$3`.
          #
          # `'{}'::text[]` and NOT `NULL` (K-788): the shipped migration
          # declares `allowed_roles text[] NOT NULL DEFAULT '{}'::text[]`, so a
          # literal NULL here made every register and every fresh-key bind 500
          # on a not-null violation for exactly the operator ADR-0011 protects
          # — "registration MUST NOT fail when [registration_role] is unset".
          # No demo could reach it (all seven configure a role) and a fake
          # accepted the statement, so the suite vouched for it for a series.
          # Not `DEFAULT` either: that defers to whatever default the operator's
          # own table happens to carry, and one that has none puts the NULL
          # straight back. An empty array SAYS "no roles" — the same move
          # `executor.rb` makes with its `"on_file"` sentinel rather than
          # writing NULL into a NOT NULL column.
          allowed_roles_sql, role_binds =
            role ? ["ARRAY[$3]::text[]", [role]] : ["'{}'::text[]", []]
          sql = <<~SQL
            INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key)
            VALUES ($1, #{allowed_roles_sql}, $2)
            RETURNING id
          SQL
          agent_id = conn.exec_query(
            sql, "Kiosk agent insert", [assistant_account_id, public_key_pem, *role_binds],
          ).to_a.first.fetch("id")
          token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
          # Wire key stays `user_id`: the factory-surface rename touches only that,
          # not the existing user_id / kiosk.current_user_id() GUC surface.
          { agent_id: agent_id, user_id: assistant_account_id.to_s, access_token: token }
        end
      end

      # Create the assistant account backing a freshly registered agent and
      # return its id (the agent's principal).
      def create_assistant_account(config, public_key_pem)
        if config.assistant_creation
          # Provider owns BOTH record creation AND id: it persists its own row
          # (bigint or uuid PK) and RETURNS the principal id, which we use
          # verbatim. `pubkey` lets it bind the account to the credential.
          id = config.assistant_creation.call(public_key_pem)
          if id.nil?
            raise Errors::ConfigurationError,
                  "config.assistant_creation returned nil. The block must create the " \
                  "assistant account and RETURN its id (used as agents.user_id), e.g. " \
                  "c.assistant_creation = ->(pubkey) { AssistantAccount.create!(...).id }"
          end
          id
        else
          config.user_model.constantize.create!.id
        end
      end
    end
  end
end
