# frozen_string_literal: true

module Kiosk
  module Server
    # A `config.spending_cap` that reads `agents.spending_cap_cents`: the cap in
    # cents, or nil (no cap, or no live assistant).
    #
    #   Kiosk.configure { |c| c.spending_cap = Kiosk::Server::ColumnSpendingCap.new }
    class ColumnSpendingCap
      def call(agent_id:)
        return nil if agent_id.nil?

        # The leased connection: the cap is read inside the transaction that charges.
        row = ::ActiveRecord::Base.lease_connection.exec_query(<<~SQL.squish, 'Kiosk spending cap', [agent_id]).to_a.first
          SELECT spending_cap_cents
          FROM "#{Kiosk.configuration.schema}".agents
          WHERE id = $1 AND revoked_at IS NULL
        SQL
        cap = row && row['spending_cap_cents']
        cap&.to_i
      end
    end
  end
end
