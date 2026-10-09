# frozen_string_literal: true

module Kiosk
  module Server
    # Stores for the PoW spent-id set (`config.pow_spent_store`). A store
    # answers `claim(id, exp)` (atomic: true iff this caller claimed it),
    # `release(id)`, `spent?(id)` and `mark_spent(id, exp)`.
    module PowSpentStores
      # The default store: the `<schema>.pow_spent` table, shared by every process.
      class ActiveRecord
        # The sweep bounds table growth; correctness does not depend on it.
        DEFAULT_PRUNE_INTERVAL = 60

        def initialize(prune_interval: DEFAULT_PRUNE_INTERVAL)
          @prune_interval = prune_interval
          @last_prune_at  = 0
          @mutex          = Mutex.new
        end

        # One statement: the primary key picks the winner; an expired row is reclaimable.
        def claim(id, exp)
          return false if id.nil?

          prune_if_due!
          sql = <<~SQL
            INSERT INTO #{table} AS s (id, expires_at)
            VALUES ($1, to_timestamp($2))
            ON CONFLICT (id) DO UPDATE
              SET expires_at = EXCLUDED.expires_at
              WHERE s.expires_at <= now()
            RETURNING s.id
          SQL
          rows = connection.exec_query(sql, "Kiosk pow_spent claim", [id, exp.to_i]).to_a
          !rows.empty?
        end

        def release(id)
          return if id.nil?

          connection.exec_query(%(DELETE FROM #{table} WHERE id = $1), "Kiosk pow_spent release", [id])
          nil
        end

        def spent?(id)
          return false if id.nil?

          sql = <<~SQL
            SELECT 1 FROM #{table}
            WHERE id = $1 AND expires_at > now()
            LIMIT 1
          SQL
          row = connection.exec_query(sql, "Kiosk pow_spent lookup", [id]).to_a.first
          !row.nil?
        end

        def mark_spent(id, exp)
          return if id.nil?

          sql = <<~SQL
            INSERT INTO #{table} (id, expires_at)
            VALUES ($1, to_timestamp($2))
            ON CONFLICT (id) DO UPDATE SET expires_at = EXCLUDED.expires_at
          SQL
          connection.exec_query(sql, "Kiosk pow_spent mark", [id, exp.to_i])
          nil
        end

        def prune!
          connection.exec_query(%(DELETE FROM #{table} WHERE expires_at <= now()), "Kiosk pow_spent prune")
          nil
        end

        private

        def prune_if_due!
          now = Time.now.to_i
          due = @mutex.synchronize do
            if now - @last_prune_at >= @prune_interval
              @last_prune_at = now
              true
            else
              false
            end
          end
          prune! if due
        end

        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".pow_spent)
      end
    end
  end
end
