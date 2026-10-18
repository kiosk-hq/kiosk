# frozen_string_literal: true

module Kiosk
  module Reputation
    module Policies
      # One proof-of-work toll per session, by chance. The chance falls linearly
      # with what the customer spent here within `within` seconds: 1 with no
      # spend, 0 at `cap` or more.
      class RecentSpend < Policy
        attr_reader :within

        # @param within [#to_i] the window in seconds, e.g. `1.week`
        # @param cap [Integer] whole currency units of recent spend at which no session pays the toll
        # @param random [#rand] the source of the draw; a test gives a fixed one
        def initialize(within:, cap:, random: Random)
          super()
          @within = within
          @cap_cents = cap * 100
          @random = random
        end

        def challenge_for(factors:, **)
          { alg: 'equihash', params: equihash_params, count: 1 } if @random.rand < chance(factors.settled_purchases_cents.to_i)
        end

        # The chance that a session pays the toll: max(0, (cap - spend) / cap).
        def chance(cents) = [(@cap_cents - cents).fdiv(@cap_cents), 0].max

        private

        # The Equihash gem's default params when it is loaded, so a test that shrinks them shrinks this toll too.
        def equihash_params = defined?(::Kiosk::Pow::Equihash) ? ::Kiosk::Pow::Equihash.params : { n: 168, k: 7 }
      end
    end
  end
end
