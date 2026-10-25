# frozen_string_literal: true

module Kiosk
  module Server
    # What an assistant spent: each settlement less what was refunded of it,
    # never below zero, one tally per currency. The «Link an assistant» page
    # shows this figure. The spending cap counts it plus the carts in flight.
    module SettledSpend
      module_function

      # The net cents of the current `settlements` row.
      def net_cents_sql(schema)
        <<~SQL.squish
          GREATEST(settlements.settled_amount_cents - (
            SELECT COALESCE(SUM(r.refunded_amount_cents), 0) FROM #{schema}.kiosk_refunds r WHERE r.settlement_id = settlements.id
          ), 0)
        SQL
      end
    end
  end
end
