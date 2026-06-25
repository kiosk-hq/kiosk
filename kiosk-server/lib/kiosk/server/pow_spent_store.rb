# frozen_string_literal: true

module Kiosk
  module Server
    # In-process TTL-keyed store for spent PoW challenge ids.
    #
    # Prevents replay of a valid, unexpired proof: once a challenge id has been
    # used successfully it is marked spent; subsequent submissions of the same id
    # are rejected as `Errors::Forbidden`.
    #
    # The store is pruned opportunistically on each `spent?` call, so memory
    # usage is bounded by the number of unexpired challenge ids seen since the
    # last prune. With a default TTL of 300 s and typical challenge rates this
    # is negligible.
    #
    # == Multi-process deployments
    #
    # This in-process store does NOT share state across web workers / Puma
    # processes — a replayed proof submitted to a different worker would be
    # accepted. Providers running multiple processes MUST override
    # `Kiosk.configure { |c| c.pow_spent_store = MyRedisSpentStore.new }`.
    # The interface contract is:
    #
    #   spent?(id)          → Boolean
    #   mark_spent(id, exp) → void   (exp is a Unix timestamp — the TTL anchor)
    class PowSpentStore
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      # @param id [String, nil] the challenge id to check
      # @return [Boolean]
      def spent?(id)
        return false if id.nil?

        prune!
        @mutex.synchronize { @store.key?(id) }
      end

      # Mark +id+ as spent until Unix timestamp +exp+.
      # @param id  [String]
      # @param exp [Integer] Unix timestamp at or after which the entry is stale
      def mark_spent(id, exp)
        return if id.nil?

        @mutex.synchronize { @store[id] = exp }
      end

      # Remove all entries whose exp has passed. Called automatically by
      # {#spent?} before each look-up.
      def prune!
        now = Time.now.to_i
        @mutex.synchronize { @store.reject! { |_, exp| exp <= now } }
      end
    end
  end
end
