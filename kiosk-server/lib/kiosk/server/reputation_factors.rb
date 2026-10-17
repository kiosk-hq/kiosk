# frozen_string_literal: true

module Kiosk
  module Server
    # The reputation inputs the engine knows itself: what the customer paid
    # here, and the visits the operator recorded, within a policy's window.
    module ReputationFactors
      module_function

      # Empty factors unless the policy names a window (`#within`, in seconds).
      def for(identity:, policy:)
        return ::Kiosk::Reputation::Factors.empty unless policy.respond_to?(:within) && identity&.user_id

        count, cents = recent_spend(identity.user_id, Time.now - policy.within.to_i)
        ::Kiosk::Reputation::Factors.empty.with(settled_purchases_count: count, settled_purchases_cents: cents)
      end

      # Settlements and visits of this customer since `since`: their count and their cents.
      def recent_spend(user_id, since)
        schema = Kiosk.configuration.schema
        sql = <<~SQL
          SELECT count(*) AS count, COALESCE(SUM(cents), 0) AS cents FROM (
            SELECT settled_amount_cents AS cents FROM "#{schema}".settlements WHERE user_id = $1 AND settled_at >= $2
            UNION ALL
            SELECT value_cents FROM "#{schema}".visits WHERE user_id = $1 AND visited_at >= $2
          ) spend
        SQL
        row = ::ActiveRecord::Base.lease_connection.exec_query(sql, 'Kiosk recent spend', [user_id, since]).to_a.first
        [row.fetch('count').to_i, row.fetch('cents').to_i]
      end
    end
  end
end
