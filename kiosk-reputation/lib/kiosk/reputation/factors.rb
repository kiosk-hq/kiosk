# frozen_string_literal: true

module Kiosk
  module Reputation
    # Reputation inputs the host supplies per request. Every field may be nil,
    # so a policy reads them through `.to_i`.
    Factors = Data.define(
      :kyc_level,
      :settled_purchases_count,
      :settled_purchases_cents,
      :request_rate_per_min,
      :account_age_seconds,
      :dispute_count,
      :bad_proof_count
    ) do
      def self.empty
        new(
          kyc_level:               nil,
          settled_purchases_count: nil,
          settled_purchases_cents: nil,
          request_rate_per_min:    nil,
          account_age_seconds:     nil,
          dispute_count:           nil,
          bad_proof_count:         nil
        )
      end
    end
  end
end
