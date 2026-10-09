# frozen_string_literal: true

module Kiosk
  module Server
    # A `config.spending_cap` that reads `agents.spending_cap_cents`: the cap in
    # cents, or nil (no cap, or no live assistant).
    #
    #   Kiosk.configure { |c| c.spending_cap = Kiosk::Server::ColumnSpendingCap.new }
    class ColumnSpendingCap
      def initialize(schema: nil, connection: nil)
        @schema     = schema
        @connection = connection
      end

      def call(agent_id:)
        return nil if agent_id.nil?

        schema = @schema || Kiosk.configuration.schema
        # The leased connection: the cap is read inside the transaction that charges.
        conn   = @connection || ::ActiveRecord::Base.lease_connection
        row = conn.exec_query(<<~SQL, "Kiosk spending cap", [agent_id]).to_a.first
          SELECT spending_cap_cents
          FROM "#{schema}".agents
          WHERE id = $1 AND revoked_at IS NULL
        SQL
        cap = row && row["spending_cap_cents"]
        cap&.to_i
      end
    end
  end
end
