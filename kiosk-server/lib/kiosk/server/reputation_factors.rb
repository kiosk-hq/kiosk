# frozen_string_literal: true

module Kiosk
  module Server
    # The reputation inputs the engine knows itself: what the customer paid
    # here and kept paid, and the visits the operator recorded, within a policy's window.
    module ReputationFactors
      module_function

      # Empty factors unless the policy names a window (`#within`, in seconds).
      def for(identity:, policy:)
        return ::Kiosk::Reputation::Factors.empty unless policy.respond_to?(:within) && identity&.user_id

        count, cents = recent_spend(identity.user_id, Time.current - policy.within.to_i)
        ::Kiosk::Reputation::Factors.empty.with(settled_purchases_count: count, settled_purchases_cents: cents)
      end

      # Settlements and visits of this customer since `since`: their count and their cents.
      # A settlement counts less what was refunded of it; one refunded in full does not count.
      def recent_spend(user_id, since)
        sql = format(RECENT_SPEND_SQL, schema: Kiosk.configuration.schema)
        row = ::ActiveRecord::Base.lease_connection.exec_query(sql, 'Kiosk recent spend', [user_id, since]).to_a.first
        [row.fetch('count').to_i, row.fetch('cents').to_i]
      end

      RECENT_SPEND_SQL = <<~SQL.squish
        SELECT count(*) AS count, COALESCE(SUM(cents), 0) AS cents FROM (
          SELECT s.settled_amount_cents - COALESCE(SUM(r.refunded_amount_cents), 0) AS cents
            FROM "%<schema>s".settlements s LEFT JOIN "%<schema>s".refunds r ON r.settlement_id = s.id
            WHERE s.user_id = $1 AND s.settled_at >= $2 GROUP BY s.id
            HAVING s.settled_amount_cents > COALESCE(SUM(r.refunded_amount_cents), 0)
          UNION ALL
          SELECT value_cents FROM "%<schema>s".visits WHERE user_id = $1 AND visited_at >= $2
        ) spend
      SQL
    end
  end
end
