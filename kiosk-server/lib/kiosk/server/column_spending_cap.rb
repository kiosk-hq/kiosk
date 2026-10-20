# frozen_string_literal: true

module Kiosk
  module Server
    # A `config.spending_cap` that reads `agents.spending_cap_cents` and
    # `agents.spending_cap_currency`: `{ amount_cents:, currency: }`, or nil (no
    # cap, or no live assistant).
    #
    #   Kiosk.configure { |c| c.spending_cap = Kiosk::Server::ColumnSpendingCap.new }
    class ColumnSpendingCap
      def call(agent_id:)
        return nil if agent_id.nil?

        # The leased connection: the cap is read inside the transaction that charges.
        row = ::ActiveRecord::Base.lease_connection.exec_query(<<~SQL.squish, 'Kiosk spending cap', [agent_id]).to_a.first
          SELECT spending_cap_cents, spending_cap_currency
          FROM "#{Kiosk.configuration.schema}".agents
          WHERE id = $1 AND revoked_at IS NULL
        SQL
        return nil if row.nil? || row['spending_cap_cents'].nil?

        { amount_cents: row['spending_cap_cents'].to_i, currency: row['spending_cap_currency'] }
      end
    end
  end
end
