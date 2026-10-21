# frozen_string_literal: true

module Kiosk
  module Server
    # Login with an already-registered public key: proves possession and mints a
    # fresh token. An unknown key is a 404, never a new account.
    module AgentLogin
      module_function

      def call(public_key_pem:, signed:)
        pem = public_key_pem.to_s.strip

        # Prove possession BEFORE any lookup or state change.
        payload = PopVerifier.verify!(public_key_pem: pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: pem, nonce: payload.fetch(:nonce))

        row      = registered_agent(pem)
        agent_id = row.fetch('id')
        role     = primary_role(row.fetch('allowed_roles'))
        token    = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        { access_token: token }
      end

      # The live agent of this key at this origin; 404 when there is none.
      def registered_agent(pem)
        row = live_agent(pem)
        return row if row

        raise Errors::NotFound.new(
          'no agent registered for this public key',
          hint: 'POST /auth/register to create an identity for a new key'
        )
      end

      def registered_agent?(pem) = !live_agent(pem).nil?

      def live_agent(pem)
        ::ActiveRecord::Base.lease_connection.exec_query(<<~SQL.squish, 'Kiosk agent lookup by key', [pem, Kiosk.current_issuer]).to_a.first
          SELECT id, user_id, allowed_roles FROM #{Kiosk.configuration.schema}.agents
          WHERE public_key = $1 AND issuer = $2 AND revoked_at IS NULL
          LIMIT 1
        SQL
      end
      private_class_method :live_agent

      # `allowed_roles` is an Array or a text[] literal ("{customer}"), by adapter.
      def primary_role(allowed_roles)
        case allowed_roles
        when Array then allowed_roles.first
        else allowed_roles.to_s.delete('{}').split(',').first
        end
      end
    end
  end
end
