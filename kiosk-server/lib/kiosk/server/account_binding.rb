# frozen_string_literal: true

module Kiosk
  module Server
    # Binds a proven public key to a human's account. A fresh key gets a new
    # linked agent row; a known key is rebound, keeping its agent_id and
    # reputation and adopting the new holder's role.
    module AccountBinding
      module_function

      # Call only after possession of `public_key_pem` has been proven.
      # `requested_role` always comes from a human's identity, never the wire.
      #
      # @return [Hash] { agent_id:, user_id:, access_token:, fresh: }
      def bind!(public_key_pem:, user_id:, requested_role: nil)
        config = Kiosk.configuration
        pem    = public_key_pem.to_s.strip
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        warn_role_resolution_not_total(config, requested_role)

        # `lease_connection`: the operator's hooks must share this transaction.
        conn = ::ActiveRecord::Base.lease_connection
        existing = conn.exec_query(<<~SQL, "Kiosk agent lookup by key", [pem, Kiosk.current_issuer]).to_a.first
          SELECT id, user_id FROM #{config.schema}.agents
          WHERE public_key = $1 AND issuer = $2 AND revoked_at IS NULL
          LIMIT 1
        SQL

        if existing
          rebind(conn, config, existing, user_id, requested_role)
        else
          register_linked(conn, config, pem, user_id, requested_role)
        end
      end

      # Revokes `agent_id`'s binding, which must belong to `user_id`; its tokens
      # stop verifying and its `/auth/login` is denied.
      #
      # @raise [Errors::NotFound] when no live agent row matches the pair.
      def unlink!(agent_id:, user_id:)
        config = Kiosk.configuration
        raise Errors::BadRequest.new("agent_id required") if agent_id.nil? || agent_id.to_s.empty?

        # The ownership predicate is the security boundary: both values are binds.
        conn = ::ActiveRecord::Base.lease_connection
        row = conn.exec_query(<<~SQL, "Kiosk agent unlink", [agent_id, user_id, Kiosk.current_issuer]).to_a.first
          UPDATE #{config.schema}.agents
          SET revoked_at = now()
          WHERE id = $1
            AND user_id = $2
            AND issuer = $3
            AND revoked_at IS NULL
          RETURNING id
        SQL
        if row.nil?
          raise Errors::NotFound.new(
            "no linked assistant account with this agent_id",
            hint: "only assistant accounts bound to the signed-in account can be unlinked",
          )
        end

        # Next second: JWT `iat` is whole seconds and the check is `iat < watermark` (§6.3).
        config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i + 1)
        config.assistant_unlinked&.call(agent: agent_id, account: config.user_model.constantize.find(user_id))
        { agent_id: agent_id }
      end

      class << self
        private

        # Known key: remap the holder and role, keep agent_id and reputation.
        # The role is never read from the row: it belonged to the previous holder.
        def rebind(conn, config, existing, user_id, requested_role = nil)
          agent_id = existing.fetch("id")
          previous = existing.fetch("user_id")
          role     = resolved_role(config, requested_role)

          # The same holder still gets the role remap and revocation; only the hook is skipped.
          transition = previous.to_s != user_id.to_s
          # An empty array cannot travel as a bind, so "no role" is a different statement.
          role_set, role_binds =
            role ? [", allowed_roles = ARRAY[$3]::text[]", [role]] : [", allowed_roles = '{}'::text[]", []]
          conn.transaction do
            conn.exec_query(<<~SQL, "Kiosk agent rebind", [user_id, agent_id, *role_binds])
              UPDATE #{config.schema}.agents
              SET user_id = $1#{role_set}
              WHERE id = $2
            SQL
            if transition && config.assistant_claimed
              accounts = config.user_model.constantize
              config.assistant_claimed.call(agent: agent_id, from: accounts.find(previous), to: accounts.find(user_id))
            end
          end

          # The old holder's tokens die (§6.3). The IdP dates new mints at the
          # watermark, so the token minted below survives it.
          config.revocation_store&.revoke_all(agent_id, at: Time.now.to_i + 1)

          token = issue_token(agent_id, role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: false }
        end

        # Fresh key: a new linked agent row under the approving human.
        def register_linked(conn, config, pem, user_id, requested_role)
          role = resolved_role(config, requested_role)

          # The column is NOT NULL: no role is `'{}'`, never NULL.
          allowed_roles_sql, role_binds =
            role ? ["ARRAY[$4]::text[]", [role]] : ["'{}'::text[]", []]
          sql = <<~SQL
            INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key, issuer)
            VALUES ($1, #{allowed_roles_sql}, $2, $3)
            RETURNING id
          SQL
          agent_id = conn.transaction do
            conn.exec_query(sql, "Kiosk linked agent insert", [user_id, pem, Kiosk.current_issuer, *role_binds])
                .to_a.first.fetch("id")
          end

          token = issue_token(agent_id, role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token, fresh: true }
        end

        # The ceremony's role, else the operator's default; never the key's previous role.
        def resolved_role(config, requested_role)
          validated_role(config, requested_role || config.registration_role)
        end

        # Rejects a role outside `config.roles`.
        def validated_role(config, candidate)
          role = candidate&.to_s
          role = nil if role && role.empty?
          if role && !config.roles.map(&:to_s).include?(role)
            raise Errors::ConfigurationError,
                  "binding role #{role.inspect} is not among configured roles #{config.roles.inspect}"
          end
          role
        end

        # An origin with several roles must resolve one for every approving human (§6.3).
        def warn_role_resolution_not_total(config, requested_role)
          return unless requested_role.nil? || requested_role.to_s.strip.empty?
          return unless config.roles.to_a.size > 1

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
          # Rails.logger is nil before the host app boots.
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.warn(message) : Kernel.warn(message)
        end

        def issue_token(agent_id, role)
          AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        end
      end
    end
  end
end
