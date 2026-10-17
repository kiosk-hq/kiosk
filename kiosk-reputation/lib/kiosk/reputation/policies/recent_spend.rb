# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # One proof-of-work toll per session, lowered by what the customer spent
      # here recently. Trust is 1.0 at `trusted_at` cents within `within`
      # seconds and falls logarithmically to 0 at no spend; the toll asks for
      # round(count * (1 - trust)) proofs, so a trusted customer pays none.
      class RecentSpend < Policy
        attr_reader :within

        # @param trusted_at [Integer] cents of recent spend that make a customer trusted
        # @param within [#to_i] the window in seconds, e.g. `1.week`
        # @param count [Integer] the proofs a customer with no recent spend solves
        def initialize(trusted_at:, within:, count: 1)
          super()
          @trusted_at = trusted_at
          @within     = within
          @count      = count
        end

        def challenge_for(factors:, **)
          proofs = (@count * (1 - trust(factors.settled_purchases_cents.to_i))).round
          { alg: 'equihash', params: equihash_params, count: proofs } if proofs.positive?
        end

        def trust(cents)
          return 1.0 if cents >= @trusted_at

          Math.log1p(cents) / Math.log1p(@trusted_at)
        end

        private

        # The Equihash gem's default params when it is loaded, so a test that shrinks them shrinks this toll too.
        def equihash_params = defined?(::Kiosk::Pow::Equihash) ? ::Kiosk::Pow::Equihash.params : { n: 168, k: 7 }
      end
    end
  end
end
