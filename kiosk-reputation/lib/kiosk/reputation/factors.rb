# frozen_string_literal: true

module Kiosk
  module Reputation
    # Reputation inputs per request. For a policy that answers `#within`, the
    # engine fills the spend from its own settlements and recorded visits, and
    # `calls_since_proof` with the account's tolled calls since its last paid
    # proof, this call included. Each field may be nil.
    Factors = Data.define(:settled_purchases_count, :settled_purchases_cents, :calls_since_proof) do
      def self.empty = new(settled_purchases_count: nil, settled_purchases_cents: nil, calls_since_proof: nil)
    end
  end
end
