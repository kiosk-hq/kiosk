# frozen_string_literal: true

require 'active_record'

module Kiosk
  module Server
    # A registered OAuth client: one live row of the agents table at the origin
    # of this request. Its `id` is both the `client_id` and the `agent_id`.
    class Client < Data.define(:id, :user_id, :public_key_pem, :allowed_roles, :issued_at)
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      CLIENT_CREDENTIALS = 'client_credentials'
      DEVICE_CODE = 'urn:ietf:params:oauth:grant-type:device_code'

      AUTH_METHOD = 'private_key_jwt'

      # The grant types this origin serves, so the grant types of every client.
      def self.grant_types(config = Kiosk.configuration)
        config.serve_account_binding ? [CLIENT_CREDENTIALS, DEVICE_CODE] : [CLIENT_CREDENTIALS]
      end

      # nil for an id that is not a UUID, so the database never sees it.
      def self.find(id)
        lookup('id = $1', id.to_s) if UUID.match?(id.to_s)
      end

      def self.with_key(key)
        lookup('public_key = $1', AssistantKey.to_pem(key))
      end

      def self.lookup(condition, value)
        row = ::ActiveRecord::Base.lease_connection.exec_query(<<~SQL.squish, 'Kiosk client lookup', [value, Kiosk.current_issuer]).to_a.first
          SELECT id, user_id, public_key, allowed_roles, extract(epoch FROM created_at)::bigint AS issued_at
          FROM #{Kiosk.configuration.schema}.kiosk_agents
          WHERE #{condition} AND issuer = $2 AND revoked_at IS NULL
          LIMIT 1
        SQL
        row && new(id: row['id'], user_id: row['user_id'], public_key_pem: row['public_key'],
                   allowed_roles: row['allowed_roles'], issued_at: row['issued_at'].to_i)
      end
      private_class_method :lookup

      def key = AssistantKey.from_pem(public_key_pem)

      def thumbprint = AssistantKey.thumbprint(key)

      # The first role. `allowed_roles` is an Array or a text[] literal ("{customer}"), by adapter.
      def role
        roles = allowed_roles.is_a?(Array) ? allowed_roles : allowed_roles.to_s.delete('{}').split(',')
        roles.first
      end

      # The RFC 7591 Section 3.2.1 client information response.
      def information
        { client_id: id, client_id_issued_at: issued_at, jwks: { keys: [AssistantKey.to_jwk(key)] },
          token_endpoint_auth_method: AUTH_METHOD, grant_types: self.class.grant_types,
          dpop_bound_access_tokens: true }
      end
    end
  end
end
