# frozen_string_literal: true

module Kiosk
  module Server
    # Greenfield self-registration: provision an id-only synthetic principal
    # and an agent bound to it, then mint the agent's first token. No human.
    module AgentRegistration
      module_function

      def call(name:, public_key_pem:, role:, pow: nil)
        config     = Kiosk.configuration
        role       = role.to_s
        difficulty = config.registration_difficulty

        unless config.roles.map(&:to_s).include?(role)
          raise Errors::BadRequest.new("role #{role.inspect} not in configured roles",
                                       hint: "Allowed: #{config.roles.inspect}")
        end

        if difficulty > 0
          unless pow && ProofOfWork.valid?(public_key_pem: public_key_pem, pow: pow, difficulty: difficulty)
            raise Errors::BadRequest.new(
              "proof-of-work required or invalid",
              hint: "Compute SHA256(public_key_pem + '.' + pow) with >= #{difficulty} leading zero bits",
            )
          end
        end

        conn = ActiveRecord::Base.connection

        # Idempotent: if an agent with this public key already exists, re-issue a token
        # instead of creating a duplicate user. This preserves the user→card mapping.
        existing = conn.execute(<<~SQL).first
          SELECT id, user_id, allowed_roles FROM #{config.schema}.agents
          WHERE public_key = #{conn.quote(public_key_pem)} AND revoked_at IS NULL
          LIMIT 1
        SQL
        if existing
          agent_id = existing.fetch("id")
          user_id  = existing.fetch("user_id")
          token    = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
          return { agent_id: agent_id, user_id: user_id.to_s, access_token: token }
        end

        conn.transaction do
          user_id  = config.user_model.constantize.create!.id
          agent_id = conn.execute(<<~SQL).first.fetch("id")
            INSERT INTO #{config.schema}.agents (user_id, name, allowed_roles, public_key)
            VALUES (#{conn.quote(user_id)}, #{conn.quote(name)},
                    ARRAY[#{conn.quote(role)}]::text[], #{conn.quote(public_key_pem)})
            RETURNING id
          SQL
          token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token }
        end
      end
    end
  end
end
