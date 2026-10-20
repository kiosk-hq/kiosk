# frozen_string_literal: true

module Kiosk
  module Server
    # The rows behind the «Link an assistant» page: an account holder's live
    # agents, and the settings the holder may edit on one of them.
    module LinkedAssistants
      module_function

      # The holder's live agents, each with its spend per currency. Without the
      # payment tables (no payment surface) an agent has no spend.
      def list(user_id)
        agents = run(agents_sql, 'Kiosk bound assistants', [user_id, Kiosk.current_issuer]).to_a
        spend = spend_by_agent(user_id)
        agents.map { |row| present(row, spend.fetch(row.fetch('id'), {})) }
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
        run(settings_sql(assignments, binds.size), 'Kiosk assistant update', binds)
      end

      class << self
        private

        def settings_sql(assignments, bind_count)
          <<~SQL.squish
            UPDATE #{Kiosk.configuration.schema}.agents
            SET #{assignments.join(', ')}
            WHERE id = $#{bind_count - 2}
              AND user_id = $#{bind_count - 1}
              AND issuer = $#{bind_count}
              AND revoked_at IS NULL
          SQL
        end

        def run(sql, name, binds) = ::ActiveRecord::Base.lease_connection.exec_query(sql, name, binds)

        def agents_sql
          <<~SQL.squish
            SELECT id, public_key, created_at, human_label, spending_cap_cents, spending_cap_currency
            FROM #{Kiosk.configuration.schema}.agents
            WHERE user_id = $1 AND issuer = $2 AND revoked_at IS NULL
            ORDER BY created_at
          SQL
        end

        # `{ agent_id => { currency => cents } }`: the figure the spending cap
        # counts, within `spending_cap_window_days` when set.
        def spend_by_agent(user_id)
          window_days = Kiosk.configuration.spending_cap_window_days&.to_i
          tally(run(spend_sql(window_days), 'Kiosk assistant spend', [user_id, Kiosk.current_issuer, *window_days]))
        rescue ::ActiveRecord::StatementInvalid => e
          raise unless missing_table?(e)

          {}
        end

        def tally(rows)
          rows.to_a.group_by { |row| row.fetch('agent_id') }.transform_values do |agent_rows|
            agent_rows.to_h { |row| [row.fetch('currency'), row.fetch('cents').to_i] }
          end
        end

        # The day count, when set, is the third bind.
        def spend_sql(window_days)
          schema = Kiosk.configuration.schema
          window = window_days ? 'AND settlements.settled_at >= now() - make_interval(days => $3)' : ''
          <<~SQL.squish
            SELECT settlements.agent_id, lower(btrim(settlements.currency)) AS currency,
                   SUM(#{SettledSpend.net_cents_sql(schema)}) AS cents
            FROM #{schema}.settlements
            JOIN #{schema}.agents ON agents.id = settlements.agent_id
            WHERE agents.user_id = $1 AND agents.issuer = $2 AND agents.revoked_at IS NULL #{window}
            GROUP BY 1, 2 ORDER BY 2
          SQL
        end

        # By class name, so this file does not load `PG`.
        def missing_table?(error)
          error.cause&.class&.name == 'PG::UndefinedTable'
        end

        def present(row, spent_cents)
          cap = row.fetch('spending_cap_cents', nil)
          {
            agent_id: row.fetch('id'),
            fingerprint: fingerprint(row.fetch('public_key')),
            created_at: row.fetch('created_at'),
            human_label: row.fetch('human_label', nil),
            spending_cap_cents: cap&.to_i,
            spending_cap_currency: row.fetch('spending_cap_currency', nil),
            spent_cents: spent_cents
          }
        end

        def fingerprint(pem)
          return '(no key)' if pem.blank?

          SigningKey.from_pem(pem).kid
        rescue StandardError
          '(unreadable key)'
        end
      end
    end
  end
end
