# frozen_string_literal: true

module Kiosk
  module Reputation
    # Reputation inputs per request. For a policy that answers `#within`, the
    # engine fills both fields from its own settlements and recorded visits.
    # Each field may be nil, so a policy reads them through `.to_i`.
    Factors = Data.define(:settled_purchases_count, :settled_purchases_cents) do
      def self.empty = new(settled_purchases_count: nil, settled_purchases_cents: nil)
    end
  end
end
