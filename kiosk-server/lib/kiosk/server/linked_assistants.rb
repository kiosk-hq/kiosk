# frozen_string_literal: true

module Kiosk
  module Server
    # The rows behind the «Link an assistant» page: an account holder's live
    # agents, and the settings the holder may edit on one of them.
    module LinkedAssistants
      module_function

      # The holder's live agents with their settled spend. Without a settlements
      # table (no payment surface) the spend falls back to 0.
      def list(user_id)
        rows =
          begin
            query(user_id, settled_spend: true)
          rescue ::ActiveRecord::StatementInvalid => e
            raise unless missing_table?(e)

            query(user_id, settled_spend: false)
          end
        rows.to_a.map { |row| present(row) }
      end

      # Column names are literals; every value, above all the free-text label, is a bind.
      def save_settings(agent_id, user_id, changes)
        binds = []
        assignments = changes.map do |column, value|
          next "#{column} = NULL" if value.nil?

          binds << value
          "#{column} = $#{binds.size}"
        end
        # The ownership predicate is the security boundary: `agent_id` from the caller, `user_id` from the session.
        binds.push(agent_id, user_id, Kiosk.current_issuer)
        ::ActiveRecord::Base.lease_connection.exec_query(settings_sql(assignments, binds.size),
                                                         'Kiosk assistant update', binds)
      end

      class << self
        private

        def settings_sql(assignments, bind_count)
          <<~SQL
            UPDATE #{Kiosk.configuration.schema}.agents
            SET #{assignments.join(', ')}
            WHERE id = $#{bind_count - 2}
              AND user_id = $#{bind_count - 1}
              AND issuer = $#{bind_count}
              AND revoked_at IS NULL
          SQL
        end

        def query(user_id, settled_spend:)
          sql, binds = list_query(Kiosk.configuration, user_id, settled_spend: settled_spend)
          ::ActiveRecord::Base.lease_connection.exec_query(sql, 'Kiosk bound assistants', binds)
        end

        # By class name, so this file does not load `PG`.
        def missing_table?(error)
          error.cause&.class&.name == 'PG::UndefinedTable'
        end

        # Returns `[sql, binds]` together: the two branches take different bind counts.
        def list_query(config, user_id, settled_spend:)
          window_days = settled_spend ? config.spending_cap_window_days&.to_i : nil
          sql = <<~SQL
            SELECT id, public_key, created_at, human_label, spending_cap_cents,
                   #{settled_cents_expr(config, settled_spend: settled_spend)} AS settled_cents
            FROM #{config.schema}.agents
            WHERE user_id = $1 AND issuer = $2 AND revoked_at IS NULL
            ORDER BY created_at
          SQL
          [sql, [user_id, Kiosk.current_issuer, *Array(window_days)]]
        end

        # This agent's settled spend, within `spending_cap_window_days` when set.
        def settled_cents_expr(config, settled_spend:)
          return '0' unless settled_spend

          window = config.spending_cap_window_days ? 'AND settled_at >= now() - make_interval(days => $3)' : ''
          <<~SQL.strip
            (SELECT COALESCE(SUM(settled_amount_cents), 0)
             FROM #{config.schema}.settlements
             WHERE agent_id = agents.id #{window})
          SQL
        end

        def present(row)
          cap = row.fetch('spending_cap_cents', nil)
          {
            agent_id: row.fetch('id'),
            fingerprint: fingerprint(row.fetch('public_key')),
            created_at: row.fetch('created_at'),
            human_label: row.fetch('human_label', nil),
            spending_cap_cents: cap&.to_i,
            settled_cents: row.fetch('settled_cents', 0).to_i
          }
        end

        def fingerprint(pem)
          return '(no key)' if pem.nil? || pem.empty?

          SigningKey.from_pem(pem).kid
        rescue StandardError
          '(unreadable key)'
        end
      end
    end
  end
end
