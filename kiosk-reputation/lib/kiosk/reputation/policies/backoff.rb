# frozen_string_literal: true

require "kiosk/reputation/backoff_store"

module Kiosk
  module Reputation
    module Policies
      # COUNT-BASED PoW backoff strategy — "solve once, next N calls free".
      #
      # After an identity solves ONE proof-of-work, it is granted a fixed COUNT
      # of subsequent ungated API requests; when that count is exhausted the
      # identity is challenged again for a fresh solve. The grant is a COUNT, not
      # a time window — a window would let a bot flood thousands of requests
      # inside it, whereas a count caps exactly how many free calls one solve
      # buys. So ONE ~9 s Equihash solve buys the next `count` calls free, then
      # the identity is re-challenged: the load-bearing "solve once, next N calls
      # free" behaviour.
      #
      # == How the grant is set and consumed
      #
      # * The grant is SET on a verified solve: the gate calls
      #   {#on_proof_verified} after it has cryptographically verified the
      #   submitted proof(s), which (re)sets this identity's remaining grants to
      #   `count`.
      # * The grant is CONSUMED by subsequent requests: each call to
      #   {#challenge_for} decrements one grant (returning nil = no challenge)
      #   until the count reaches zero, at which point a fresh challenge (a dup of
      #   `base`) is issued.
      #
      # This inverts the usual "cost per request" model into "cost per burst":
      # the toll is paid once, up front, and amortised over the next `count`
      # calls. It is a pure operator-side reputation config — transparent to the
      # AI assistant, which just sees fewer 402s; "solve every challenge and
      # retry" still holds.
      #
      # == Constructor params
      # @param count [Integer] ungated requests granted by ONE solved proof (>= 1)
      # @param base  [Hash] the challenge spec `{alg:, params:, count:}` issued
      #   when the identity has no remaining grants (the cost of a fresh solve).
      #   `count` here is the per-challenge PoW proof count (N×PoW), distinct from
      #   the `count` grant above.
      # @param store [#grant, #consume] the counter store (defaults to a fresh
      #   in-process {BackoffStore}; pass a shared Redis/DB store in production)
      #
      # @see BackoffStore
      class Backoff < Policy
        # @param count [Integer]
        # @param base  [Hash]
        # @param store [#grant, #consume]
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

        # Consume a grant if one is available, else issue a fresh challenge.
        #
        # @param identity [Object] the Kiosk::Identity (or opaque identity value)
        # @param verb     [Symbol] the Kiosk verb (unused — the backoff is per
        #   identity across all verbs; subclass to scope by verb)
        # @param factors  [Factors] reputation factors (unused by this strategy)
        # @return [Hash, nil] nil when a grant was available and consumed (serve
        #   without challenge); a dup of `base` when the identity must solve again
        def challenge_for(identity:, verb:, factors:)
          key = identity_key(identity)
          return nil if @store.consume(key)

          @base.dup
        end

        # Grant this identity `count` ungated requests. Called by the gate after
        # it verifies a submitted proof — a fresh solve RESETS (does not
        # accumulate) the remaining grants to `count`.
        #
        # @param identity [Object] the Kiosk::Identity (or opaque identity value)
        # @return [void]
        def on_proof_verified(identity:)
          @store.grant(identity_key(identity), @count)
        end

        private

        # A stable per-identity string key.
        #
        # Handles both the {Kiosk::Identity} Data object (prefers the specific
        # agent credential, then the principal id) and a plain string / opaque
        # identity value. An agent and its owning user are keyed separately (an
        # agent has a distinct `agent_id`), so each agent credential earns and
        # spends its own grant.
        #
        # @param identity [Object]
        # @return [String]
        def identity_key(identity)
          agent_id = identity.respond_to?(:agent_id) ? identity.agent_id : nil
          user_id  = identity.respond_to?(:user_id)  ? identity.user_id  : nil

          (agent_id || user_id || identity).to_s
        end
      end
    end
  end
end
