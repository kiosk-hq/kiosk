# frozen_string_literal: true

require 'active_record'
require 'active_support/core_ext/string/inflections' # String#constantize

module Kiosk
  module Server
    # RFC 7591 open registration of an AI assistant's public key, with no human:
    # creates the assistant account and its client. A key with a live client
    # gets that client again, so an assistant that lost its client_id recovers it.
    module ClientRegistration
      module_function

      # @param metadata [Hash] the parsed request body
      # @return [Client]
      # @raise [OauthError] `invalid_client_metadata`
      def call(metadata, pow: nil)
        config = Kiosk.configuration
        role   = registration_role(config)
        key    = checked_key(metadata)

        AuthToll.gate(verb: 'oauth/register', body: { key: AssistantKey.thumbprint(key) }, pow: pow, config: config)
        Client.with_key(key) || register(config, key, role)
      end

      def checked_key(metadata)
        invalid!('the request body must be a JSON object') unless metadata.is_a?(Hash)
        metadata = metadata.transform_keys(&:to_s)
        method = metadata['token_endpoint_auth_method']
        invalid!("token_endpoint_auth_method must be #{Client::AUTH_METHOD}") unless [nil, Client::AUTH_METHOD].include?(method)
        check_grant_types!(metadata['grant_types'])
        AssistantKey.from_jwks(metadata['jwks'])
      rescue Errors::BadRequest => e
        invalid!("jwks: #{e.message}; #{e.hint}")
      end

      def check_grant_types!(grant_types)
        return if grant_types.nil?
        return if grant_types.is_a?(Array) && (grant_types - Client.grant_types).empty?

        invalid!("grant_types must be a list of the grant types this origin serves: #{Client.grant_types.join(', ')}")
      end

      # The operator's `assistant_creation` factory, else a bare `user_model.create!`.
      def create_assistant_account(config, pem)
        return config.user_model.constantize.create!.id unless config.assistant_creation

        id = config.assistant_creation.call(pem)
        return id unless id.nil?

        raise Errors::ConfigurationError,
              'config.assistant_creation returned nil. The block must create the ' \
              'assistant account and RETURN its id (used as agents.user_id), e.g. ' \
              'c.assistant_creation = ->(pubkey) { AssistantAccount.create!(...).id }'
      end

      # The role is the server's choice, never the assistant's.
      def registration_role(config)
        role = config.registration_role&.to_s
        return if role.blank?
        return role if config.roles.map(&:to_s).include?(role)

        raise Errors::ConfigurationError,
              "registration_role #{role.inspect} is not among configured roles " \
              "#{config.roles.inspect}"
      end

      # The live unique index on (issuer, public_key) picks the winner of a race.
      def register(config, key, role)
        pem = AssistantKey.to_pem(key)
        conn = ::ActiveRecord::Base.lease_connection
        conn.transaction(requires_new: true) do
          account = create_assistant_account(config, pem)
          AssistantAccounts.record!(account)
          insert_agent(conn, config, [account, pem], role)
        end
        Client.with_key(key)
      rescue ::ActiveRecord::RecordNotUnique
        Client.with_key(key)
      end

      # No role is the empty array: `allowed_roles` is NOT NULL.
      def insert_agent(conn, config, binds, role)
        allowed_roles_sql, role_binds = role ? ['ARRAY[$4]::text[]', [role]] : ["'{}'::text[]", []]
        conn.exec_query(<<~SQL.squish, 'Kiosk agent insert', [*binds, Kiosk.current_issuer, *role_binds])
          INSERT INTO #{config.schema}.kiosk_agents (user_id, public_key, issuer, allowed_roles)
          VALUES ($1, $2, $3, #{allowed_roles_sql})
        SQL
      end

      def invalid!(description)
        raise OauthError.new(:invalid_client_metadata, description)
      end

      private_class_method :checked_key, :check_grant_types!, :registration_role, :register, :insert_agent, :invalid!
    end
  end
end
