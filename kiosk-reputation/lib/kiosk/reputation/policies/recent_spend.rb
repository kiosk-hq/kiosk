# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # One proof-of-work toll on every Nth tolled call of an account. N grows
      # with what the customer spent here within `within` seconds:
      # N = ceil(10 / share), share = max(0, (cap - spend) / cap). So a customer
      # with no spend solves the toll on every 10th call, at half the cap on every 20th, and
      # at `cap` or more on none.
      class RecentSpend < Policy
        # The tolled calls per proof of a customer with no recent spend.
        BASE_INTERVAL = 10

        attr_reader :within

        # @param within [#to_i] the window in seconds, e.g. `1.week`
        # @param cap [Integer] whole currency units of recent spend at which no call is tolled
        def initialize(within:, cap:)
          super()
          @within = within
          @cap_cents = cap * 100
        end

        # A caller the engine does not count (no `calls_since_proof`) solves the toll on every call that the interval tolls.
        def challenge_for(factors:, **)
          every = interval(factors.settled_purchases_cents.to_i)
          calls = factors.calls_since_proof
          { alg: 'equihash', params: equihash_params, count: 1 } if every && (calls.nil? || calls >= every)
        end

        # The tolled calls per proof: ceil(10 / share), with share = (cap - spend) / cap; nil at `cap` or more.
        def interval(cents)
          Rational(BASE_INTERVAL * @cap_cents, @cap_cents - cents).ceil if cents < @cap_cents
        end

        private

        # The Equihash gem's default params when it is loaded, so a test that shrinks them shrinks this toll too.
        def equihash_params = defined?(::Kiosk::Pow::Equihash.params) ? ::Kiosk::Pow::Equihash.params : { n: 168, k: 7 }
      end
    end
  end
end
