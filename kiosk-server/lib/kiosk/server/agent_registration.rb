# frozen_string_literal: true

module Kiosk
  module Server
    # Greenfield self-registration: provision the assistant account backing the
    # agent, bind an agent to it, then mint the agent's first token. No human.
    #
    # The assistant account is created either by a provider-supplied factory
    # (`config.assistant_creation`, ADR-0010) or, when none is configured, by a
    # bare `user_model.create!` (the greenfield fallback — see #call).
    module AgentRegistration
      module_function

      def call(public_key_pem:, signed:, pow: nil)
        config = Kiosk.configuration
        role   = config.registration_role&.to_s
        role   = nil if role && role.empty?

        # The role is pinned server-side when configured — the agent never
        # sends one (that would be a privilege-selection primitive). OPTIONAL
        # per ADR-0011 (roles are hook-or-absent in 0.1): when unset, the agent
        # row gets NO role, and the provider may instead assign roles inside
        # its `assistant_creation` hook. A CONFIGURED role that is not among
        # the declared roles is still a provider error (loud 500).
        if role && !config.roles.map(&:to_s).include?(role)
          raise Errors::ConfigurationError,
                "registration_role #{role.inspect} is not among configured roles " \
                "#{config.roles.inspect}"
        end

        # Normalise PEM: strip leading/trailing whitespace so lookup matches storage.
        public_key_pem = public_key_pem.strip

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

        conn = ActiveRecord::Base.connection

        # A known public key is NOT re-registered — that would be a second way to
        # mint an identity for an existing key (and the old idempotent re-issue
        # blurred register vs. login). Existing keys refresh their token through
        # POST /auth/login instead.
        existing = conn.execute(<<~SQL).first
          SELECT id FROM #{config.schema}.agents
          WHERE public_key = #{conn.quote(public_key_pem)} AND revoked_at IS NULL
          LIMIT 1
        SQL
        if existing
          raise Errors::Conflict.new(
            "public key already registered",
            hint: "use POST /auth/login to refresh a token for an existing key",
          )
        end

        conn.transaction do
          # The principal backing this agent is an ASSISTANT ACCOUNT (ADR-0010),
          # not necessarily a human user. Prefer the provider-supplied factory:
          # the provider creates its OWN record (satisfying its own model
          # validations) and RETURNS the principal id, which the framework uses
          # verbatim as `agents.user_id` — so it works for bigint AND uuid PKs.
          # Fall back to a bare `create!` only when no factory is configured —
          # that path 500s on any model with required attributes, which is
          # exactly why `assistant_creation` exists.
          assistant_account_id = create_assistant_account(config, public_key_pem)

          # NULL allowed_roles when no registration_role is configured
          # (ADR-0011: single-role providers need no role at all).
          allowed_roles_sql = role ? "ARRAY[#{conn.quote(role)}]::text[]" : "NULL"
          agent_id = conn.execute(<<~SQL).first.fetch("id")
            INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key)
            VALUES (#{conn.quote(assistant_account_id)},
                    #{allowed_roles_sql}, #{conn.quote(public_key_pem)})
            RETURNING id
          SQL
          token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
          # Wire key stays `user_id`: ADR-0010 renames the factory surface only,
          # not the existing user_id / kiosk.current_user_id() GUC surface.
          { agent_id: agent_id, user_id: assistant_account_id.to_s, access_token: token }
        end
      end

      # Create the assistant account backing a freshly registered agent and
      # return its id (the agent's principal). ADR-0010.
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
