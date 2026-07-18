# frozen_string_literal: true

module Kiosk
  module Server
    # A ready-made `config.spending_cap` seam (ADR-0019) that reads the
    # per-assistant cap from the `agents.spending_cap_cents` column — the column
    # added by {SchemaDefinitions.agent_governance_columns_sql} and edited by the
    # manage-assistants page. Providers that store caps elsewhere supply their
    # own `(agent_id:) -> Integer | nil` callable instead.
    #
    #   Kiosk.configure { |c| c.spending_cap = Kiosk::Server::ColumnSpendingCap.new }
    #
    # Returns the cap in cents, or nil when the assistant row has no cap set
    # (unlimited) or the key is unknown/revoked.
    class ColumnSpendingCap
      # @param schema [String, nil] overrides Kiosk.configuration.schema
      # @param connection [#execute, #quote, nil] overrides ActiveRecord::Base.connection
      #   (mainly for tests; a Rails host leaves it nil)
      def initialize(schema: nil, connection: nil)
        @schema     = schema
        @connection = connection
      end

      def call(agent_id:)
        return nil if agent_id.nil?

        schema = @schema || Kiosk.configuration.schema
        conn   = @connection || ::ActiveRecord::Base.connection
        row = conn.execute(<<~SQL).to_a.first
          SELECT spending_cap_cents
          FROM "#{schema}".agents
          WHERE id = #{conn.quote(agent_id)} AND revoked_at IS NULL
        SQL
        cap = row && row["spending_cap_cents"]
        cap&.to_i
      end
    end
  end
end
