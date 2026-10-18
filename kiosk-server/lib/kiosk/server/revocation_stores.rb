# frozen_string_literal: true

module Kiosk
  module Server
    # Stores for `config.revocation_store`. A store answers
    # `revoke_all(agent_id, at:)`, `watermark_for(agent_id)` and
    # `revoked?(agent_id:, iat:)`: a token whose `iat` is strictly before the
    # agent's watermark is revoked.
    module RevocationStores
      # The default store: the `<schema>.revocations` table, shared by every
      # process and kept across restarts. A token of an unlinked or deleted
      # agent is revoked too.
      class ActiveRecord
        # The watermark only moves forward.
        def revoke_all(agent_id, at:)
          return if agent_id.nil?

          connection.exec_query(<<~SQL.squish, 'Kiosk revocation', [agent_id, at.to_i])
            INSERT INTO #{table('revocations')} AS r (agent_id, revoked_before)
            VALUES ($1, to_timestamp($2))
            ON CONFLICT (agent_id) DO UPDATE
              SET revoked_before = GREATEST(r.revoked_before, EXCLUDED.revoked_before)
          SQL
          nil
        end

        def watermark_for(agent_id)
          return nil if agent_id.nil?

          row = connection.exec_query(<<~SQL.squish, 'Kiosk revocation watermark', [agent_id]).to_a.first
            SELECT extract(epoch FROM revoked_before)::bigint AS at
            FROM #{table('revocations')} WHERE agent_id = $1
          SQL
          row&.fetch('at')
        end

        def revoked?(agent_id:, iat:)
          return false if agent_id.nil? || iat.nil?

          connection.exec_query(<<~SQL.squish, 'Kiosk revocation check', [agent_id, iat.to_i]).to_a.empty?
            SELECT 1
            FROM #{table('agents')} a
            LEFT JOIN #{table('revocations')} r ON r.agent_id = a.id
            WHERE a.id = $1
              AND a.revoked_at IS NULL
              AND (r.revoked_before IS NULL OR r.revoked_before <= to_timestamp($2))
          SQL
        end

        private

        def connection = ::ActiveRecord::Base.lease_connection
        def table(name) = %("#{Kiosk.configuration.schema}".#{name})
      end
    end
  end
end
