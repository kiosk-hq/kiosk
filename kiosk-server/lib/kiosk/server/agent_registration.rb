# frozen_string_literal: true

module Kiosk
  module Server
    # Greenfield self-registration: provision an id-only synthetic principal
    # and an agent bound to it, then mint the agent's first token. No human.
    module AgentRegistration
      module_function

      def call(name:, public_key_pem:, role:)
        config = Kiosk.configuration
        role   = role.to_s
        unless config.roles.map(&:to_s).include?(role)
          raise Errors::BadRequest.new("role #{role.inspect} not in configured roles",
                                       hint: "Allowed: #{config.roles.inspect}")
        end

        conn = ActiveRecord::Base.connection
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
