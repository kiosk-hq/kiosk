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
            UPDATE #{Kiosk.configuration.schema}.kiosk_agents
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
            SELECT id, public_key, bound_at, human_label, spending_cap_cents, spending_cap_currency
            FROM #{Kiosk.configuration.schema}.kiosk_agents
            WHERE user_id = $1 AND issuer = $2 AND revoked_at IS NULL
            ORDER BY created_at
          SQL
        end

        # `{ agent_id => { currency => cents } }`: what each agent spent.
        def spend_by_agent(user_id)
          tally(run(spend_sql, 'Kiosk assistant spend', [user_id, Kiosk.current_issuer]))
        rescue ::ActiveRecord::StatementInvalid => e
          raise unless missing_table?(e)

          {}
        end

        def tally(rows)
          rows.to_a.group_by { |row| row.fetch('agent_id') }.transform_values do |agent_rows|
            agent_rows.to_h { |row| [row.fetch('currency'), row.fetch('cents').to_i] }
          end
        end

        # Each settlement less what was refunded of it, never below zero, one
        # tally per currency.
        def spend_sql
          schema = Kiosk.configuration.schema
          <<~SQL.squish
            SELECT settlements.agent_id, lower(btrim(settlements.currency)) AS currency,
                   SUM(GREATEST(settlements.settled_amount_cents - (
                     SELECT COALESCE(SUM(r.refunded_amount_cents), 0) FROM #{schema}.kiosk_refunds r WHERE r.settlement_id = settlements.id
                   ), 0)) AS cents
            FROM #{schema}.kiosk_settlements settlements
            JOIN #{schema}.kiosk_agents agents ON agents.id = settlements.agent_id
            WHERE agents.user_id = $1 AND agents.issuer = $2 AND agents.revoked_at IS NULL
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
            bound_at: row.fetch('bound_at', nil),
            human_label: row.fetch('human_label', nil),
            spending_cap_cents: cap&.to_i,
            spending_cap_currency: row.fetch('spending_cap_currency', nil),
            spent_cents: spent_cents
          }
        end

        def fingerprint(pem)
          return '(no key)' if pem.blank?

          AssistantKey.thumbprint(AssistantKey.from_pem(pem))
        rescue StandardError
          '(unreadable key)'
        end
      end
    end
  end
end
