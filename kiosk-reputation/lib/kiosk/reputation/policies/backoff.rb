# frozen_string_literal: true

require "kiosk/reputation/backoff_store"

module Kiosk
  module Reputation
    module Policies
      # "Solve once, next `count` calls free", per identity. A count rather than
      # a time window, so one solve buys a fixed number of calls.
      class Backoff < Policy
        # `base` is the challenge spec issued once the grants run out.
        def initialize(count:, base:, store: BackoffStore.new)
          count = Integer(count)
          raise ArgumentError, "count must be >= 1 (got #{count})" if count < 1

          unless base.is_a?(Hash) && !base[:alg].to_s.empty? && base[:params]
            raise ArgumentError,
                  "base must be a challenge spec Hash with :alg and :params (got #{base.inspect})"
          end

          super()
          @count = count
          @base  = base.dup.freeze
          @store = store
        end

        def challenge_for(identity:, verb:, factors:)
          key = identity_key(identity)
          return nil if @store.consume(key)

          @base.dup
        end

        # Called by the gate after a verified solve; resets, does not accumulate.
        def on_proof_verified(identity:)
          @store.grant(identity_key(identity), @count)
        end

        private

        # Each agent credential earns and spends its own grant.
        def identity_key(identity)
          agent_id = identity.respond_to?(:agent_id) ? identity.agent_id : nil
          user_id  = identity.respond_to?(:user_id)  ? identity.user_id  : nil

          (agent_id || user_id || identity).to_s
        end
      end
    end
  end
end
