# frozen_string_literal: true

require 'digest'

module Kiosk
  module Reputation
    module Policies
      # One proof-of-work toll per session, by chance. The chance falls linearly
      # with what the customer spent here within `within` seconds: 1 with no
      # spend, 0 at `cap` or more. The draw is made once per customer and token
      # lifetime, so a new token minted in the same lifetime meets the same outcome.
      class RecentSpend < Policy
        attr_reader :within

        # @param within [#to_i] the window in seconds, e.g. `1.week`
        # @param cap [Integer] whole currency units of recent spend at which no session pays the toll
        def initialize(within:, cap:)
          super()
          @within = within
          @cap_cents = cap * 100
        end

        def challenge_for(identity:, factors:, **)
          { alg: 'equihash', params: equihash_params, count: 1 } if draw(identity) < chance(factors.settled_purchases_cents.to_i)
        end

        # The chance that a session pays the toll: max(0, (cap - spend) / cap).
        def chance(cents) = [(@cap_cents - cents).fdiv(@cap_cents), 0].max

        private

        # A number in [0, 1), set by the customer and the token lifetime that holds
        # the token's `iat`: lifetimes are consecutive spans of `exp - iat` seconds
        # from the Unix epoch. A caller without a token draws anew.
        def draw(identity)
          claims = identity&.claims || {}
          return rand unless claims[:iat] && claims[:exp]

          span = claims[:iat].div(claims[:exp] - claims[:iat])
          Digest::SHA256.digest("#{identity.user_id}:#{span}").unpack1('Q>').fdiv(2**64)
        end

        # The Equihash gem's default params when it is loaded, so a test that shrinks them shrinks this toll too.
        def equihash_params = defined?(::Kiosk::Pow::Equihash) ? ::Kiosk::Pow::Equihash.params : { n: 168, k: 7 }
      end
    end
  end
end
