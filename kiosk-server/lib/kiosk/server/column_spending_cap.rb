# frozen_string_literal: true

module Kiosk
  module Server
    # A ready-made `config.spending_cap` seam that reads the
    # per-assistant cap from the `agents.spending_cap_cents` column — declared by
    # {SchemaDefinitions.identity_tables_sql} (migration 002) and edited by the
    # manage-assistants page. Providers that store caps elsewhere supply their
    # own `(agent_id:) -> Integer | nil` callable instead.
    #
    #   Kiosk.configure { |c| c.spending_cap = Kiosk::Server::ColumnSpendingCap.new }
    #
    # Returns the cap in cents, or nil when the assistant row has no cap set
    # (unlimited) or the key is unknown/revoked.
    class ColumnSpendingCap
      # @param schema [String, nil] overrides Kiosk.configuration.schema
      # @param connection [#exec_query, nil] overrides
      #   ActiveRecord::Base.lease_connection (mainly for tests; a Rails host
      #   leaves it nil)
      def initialize(schema: nil, connection: nil)
        @schema     = schema
        @connection = connection
      end

      def call(agent_id:)
        return nil if agent_id.nil?

        schema = @schema || Kiosk.configuration.schema
        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`. Not `with_connection`:
        # this seam is called from `Executor#enforce_spending_cap!` INSIDE the
        # phase-1 transaction, and reading the cap on a different connection
        # would read outside the transaction that is about to charge.
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
