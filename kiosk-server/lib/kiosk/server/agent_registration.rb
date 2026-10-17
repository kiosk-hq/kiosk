# frozen_string_literal: true

require 'active_record'
require 'active_support/core_ext/string/inflections' # String#constantize

module Kiosk
  module Server
    # Self-registration with no human: creates the assistant account, binds an
    # agent to the key, and mints its first token.
    module AgentRegistration
      module_function

      def call(public_key_pem:, signed:, pow: nil)
        config = Kiosk.configuration
        role   = registration_role(config)
        public_key_pem = public_key_pem.to_s.strip

        RegistrationPow.gate(public_key_pem: public_key_pem, pow: pow, config: config)

        # Prove possession of the private key before any lookup or write.
        payload = PopVerifier.verify!(public_key_pem: public_key_pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: public_key_pem, nonce: payload.fetch(:nonce))

        conn = ::ActiveRecord::Base.lease_connection
        refuse_known_key!(conn, config, public_key_pem)
        conn.transaction { register(conn, config, public_key_pem, role) }
      end

      # The operator's `assistant_creation` factory, else a bare `user_model.create!`.
      def create_assistant_account(config, public_key_pem)
        return config.user_model.constantize.create!.id unless config.assistant_creation

        id = config.assistant_creation.call(public_key_pem)
        return id unless id.nil?

        raise Errors::ConfigurationError,
              'config.assistant_creation returned nil. The block must create the ' \
              'assistant account and RETURN its id (used as agents.user_id), e.g. ' \
              'c.assistant_creation = ->(pubkey) { AssistantAccount.create!(...).id }'
      end

      # The role is the server's choice, never the agent's.
      def registration_role(config)
        role = config.registration_role&.to_s
        return if role.nil? || role.empty?
        return role if config.roles.map(&:to_s).include?(role)

        raise Errors::ConfigurationError,
              "registration_role #{role.inspect} is not among configured roles " \
              "#{config.roles.inspect}"
      end

      # A known key logs in instead; it is never registered twice.
      def refuse_known_key!(conn, config, public_key_pem)
        existing = conn.exec_query(<<~SQL, 'Kiosk agent lookup by key', [public_key_pem, Kiosk.current_issuer]).to_a.first
          SELECT id FROM #{config.schema}.agents
          WHERE public_key = $1 AND issuer = $2 AND revoked_at IS NULL
          LIMIT 1
        SQL
        return unless existing

        raise Errors::Conflict.new(
          'public key already registered',
          hint: 'use POST /auth/login to refresh a token for an existing key'
        )
      end

      def register(conn, config, public_key_pem, role)
        assistant_account_id = create_assistant_account(config, public_key_pem)
        agent_id = insert_agent(conn, config, [assistant_account_id, public_key_pem, Kiosk.current_issuer], role)
        token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        { agent_id: agent_id, user_id: assistant_account_id.to_s, access_token: token }
      end

      # No role is the empty array: `allowed_roles` is NOT NULL.
      def insert_agent(conn, config, binds, role)
        allowed_roles_sql, role_binds = role ? ['ARRAY[$4]::text[]', [role]] : ["'{}'::text[]", []]
        rows = conn.exec_query(<<~SQL, 'Kiosk agent insert', [*binds, *role_binds])
          INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key, issuer)
          VALUES ($1, #{allowed_roles_sql}, $2, $3)
          RETURNING id
        SQL
        rows.to_a.first.fetch('id')
      end
      private_class_method :registration_role, :refuse_known_key!, :register, :insert_agent
    end
  end
end
