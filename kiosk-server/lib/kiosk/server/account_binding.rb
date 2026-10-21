# frozen_string_literal: true

module Kiosk
  module Server
    # Binds a registered client to a human's account: the client keeps its
    # agent_id and reputation and takes the role of its new holder.
    module AccountBinding
      module_function

      # Call only after the client has authenticated.
      # `requested_role` always comes from a human's identity, never the wire.
      #
      # @return [Client] the client under its new holder
      def bind!(agent_id:, user_id:, requested_role: nil)
        config = Kiosk.configuration
        raise ArgumentError, 'user_id required' if user_id.nil? || user_id.to_s.empty?

        client = Client.find(agent_id) || raise(ArgumentError, "no live client #{agent_id.inspect} at this origin")
        warn_role_resolution_not_total(config, requested_role)
        rebind(::ActiveRecord::Base.lease_connection, config, client, user_id, requested_role)
        Client.find(agent_id)
      end

      # Revokes `agent_id`'s binding, which must belong to `user_id`; its tokens
      # stop verifying and the token endpoint refuses it.
      #
      # @raise [Errors::NotFound] when no live agent row matches the pair.
      def unlink!(agent_id:, user_id:)
        config = Kiosk.configuration
        raise Errors::BadRequest, 'agent_id required' if agent_id.nil? || agent_id.to_s.empty?

        # The ownership predicate is the security boundary: both values are binds.
        raise not_linked unless Rows.revoke_owned(::ActiveRecord::Base.lease_connection, config.schema, agent_id, user_id)

        revoke_tokens(config, agent_id)
        config.assistant_unlinked&.call(agent: agent_id, account: config.user_model.constantize.find(user_id))
        { agent_id: agent_id }
      end

      ROLE_NOT_TOTAL =
        '[kiosk-server] an account-binding ceremony resolved NO role for the approving ' \
        'human, and this origin declares more than one role ' \
        '(%<roles>s). Role resolution must be TOTAL: an operator that ' \
        'assigns roles at all assigns one to EVERY human who can approve a binding. A ' \
        'role for staff and nothing for customers is not a supported configuration — ' \
        'this binding lands on %<role>s, the role registration would assign, so a human ' \
        'who should hold a privileged one gets an assistant ' \
        'that cannot act for them. Fix the identity system, not the ceremony: a ' \
        '`#kiosk_role` that can answer nil is the usual cause, and returning the ' \
        'least-privileged declared role instead makes it total.'
      private_constant :ROLE_NOT_TOTAL

      class << self
        private

        # Remaps the holder and role, keeps agent_id and reputation.
        # The role is never read from the row: it belonged to the previous holder.
        def rebind(conn, config, client, user_id, requested_role)
          role = resolved_role(config, requested_role)
          # The same holder still gets the role remap and revocation; only the hook is skipped.
          transition = client.user_id.to_s != user_id.to_s
          conn.transaction do
            Rows.rebind(conn, config.schema, client.id, user_id, role)
            claimed(config, client.id, client.user_id, user_id) if transition && config.assistant_claimed
          end
          # The old holder's tokens die (§6.3). The IdP dates new mints at the
          # watermark, so a token minted after this survives it.
          revoke_tokens(config, client.id)
        end

        # §6.3: the tokens of the previous holder stop.
        def revoke_tokens(config, agent_id)
          RevocationStores.revoke_issued(agent_id, store: config.revocation_store)
        end

        def claimed(config, agent_id, previous, user_id)
          accounts = config.user_model.constantize
          config.assistant_claimed.call(agent: agent_id, from: accounts.find(previous), to: accounts.find(user_id))
        end

        def not_linked
          Errors::NotFound.new(
            'no linked assistant account with this agent_id',
            hint: 'only assistant accounts bound to the signed-in account can be unlinked'
          )
        end

        # The ceremony's role, else the operator's default; never the key's previous role.
        def resolved_role(config, requested_role)
          validated_role(config, requested_role || config.registration_role)
        end

        # Rejects a role outside `config.roles`.
        def validated_role(config, candidate)
          role = candidate&.to_s
          role = nil if role && role.empty?
          if role && config.roles.map(&:to_s).exclude?(role)
            raise Errors::ConfigurationError,
                  "binding role #{role.inspect} is not among configured roles #{config.roles.inspect}"
          end
          role
        end

        # An origin with several roles must resolve one for every approving human (§6.3).
        def warn_role_resolution_not_total(config, requested_role)
          return unless requested_role.nil? || requested_role.to_s.strip.empty?
          return unless config.roles.to_a.size > 1

          log_warning(format(ROLE_NOT_TOTAL, roles: config.roles.inspect, role: config.registration_role.inspect))
        end

        # Rails.logger is nil before the host app boots.
        def log_warning(message)
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.warn(message) : Kernel.warn(message)
        end
      end

      # The agents-table statements a binding runs.
      module Rows
        module_function

        def revoke_owned(conn, schema, agent_id, user_id)
          conn.exec_query(<<~SQL.squish, 'Kiosk agent unlink', [agent_id, user_id, Kiosk.current_issuer]).to_a.first
            UPDATE #{schema}.agents
            SET revoked_at = now()
            WHERE id = $1
              AND user_id = $2
              AND issuer = $3
              AND revoked_at IS NULL
            RETURNING id
          SQL
        end

        # An empty array cannot travel as a bind, so "no role" is a different statement.
        def rebind(conn, schema, agent_id, user_id, role)
          role_set, role_binds =
            role ? [', allowed_roles = ARRAY[$3]::text[]', [role]] : [", allowed_roles = '{}'::text[]", []]
          conn.exec_query(<<~SQL.squish, 'Kiosk agent rebind', [user_id, agent_id, *role_binds])
            UPDATE #{schema}.agents
            SET user_id = $1#{role_set}
            WHERE id = $2
          SQL
        end
      end
      private_constant :Rows
    end
  end
end
