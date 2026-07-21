# frozen_string_literal: true

module Kiosk
  module Reputation
    # In-process, Mutex-guarded counter store for the {Policies::Backoff}
    # count-based PoW backoff strategy.
    #
    # One solved proof GRANTS an identity a fixed number of subsequent ungated
    # requests. This store holds the per-identity remaining-grant COUNT: a solve
    # (re)sets it via {#grant}; each following request CONSUMES one via
    # {#consume}. A COUNT — not a time window — is deliberate: a window would let
    # a bot flood thousands of requests inside it, whereas a count caps exactly
    # how many free calls one ~9 s solve buys.
    #
    # == Interface contract
    #
    # A production app may swap in a shared backend (Redis / DB) by passing any
    # object with the SAME two methods:
    #
    #   grant(key, n)  → void     (set the remaining-grant count for key to n)
    #   consume(key)   → Boolean  (if count > 0: decrement and return true;
    #                              else return false — atomically)
    #
    # {#consume} MUST decrement-and-test atomically so two concurrent requests
    # can never both consume the last remaining grant.
    #
    # == Multi-process deployments
    #
    # This in-process store does NOT share state across web workers / Puma
    # processes. Each worker keeps its OWN counter, so the effective grant is
    # PER-WORKER: with W workers an identity may receive up to `count` free calls
    # from each worker it happens to hit before being re-challenged there. The
    # COUNT is authoritative only per worker. A provider running multiple
    # processes MUST override with a shared store:
    #
    #   Kiosk.configure { |c| c.reputation_policy =
    #     Kiosk::Reputation::Policies::Backoff.new(
    #       count: 50, base: {...}, store: MyRedisBackoffStore.new) }
    #
    # (Mirrors {Kiosk::Server::PowSpentStore}'s in-process default + cross-worker
    # caveat.)
    class BackoffStore
      def initialize
        @counter = {}
        @mutex   = Mutex.new
      end

      # (Re)set the remaining-grant count for +key+ to +n+.
      # Called after a proof is verified — one solve buys +n+ free calls.
      #
      # @param key [String] the identity key
      # @param n   [Integer] grants to set (a fresh solve resets, not accumulates)
      # @return [void]
      def grant(key, n)
        @mutex.synchronize { @counter[key] = n.to_i }
        nil
      end

      # Consume one grant for +key+ if any remain.
      #
      # @param key [String] the identity key
      # @return [Boolean] true if a grant was available and consumed
      #   (serve WITHOUT a challenge); false if none remain (issue a challenge)
      def consume(key)
        @mutex.synchronize do
          remaining = @counter[key].to_i
          if remaining.positive?
            @counter[key] = remaining - 1
            true
          else
            false
          end
        end
      end
    end
  end
end
