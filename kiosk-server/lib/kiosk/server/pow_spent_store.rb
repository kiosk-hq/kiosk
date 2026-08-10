# frozen_string_literal: true

module Kiosk
  module Server
    # In-process TTL-keyed store for spent PoW challenge ids.
    #
    # Prevents replay of a valid, unexpired proof from counting toward the PoW
    # quota: once a challenge id has been used successfully it is marked spent.
    # A subsequent submission of the same id is NOT bad faith (an at-least-once
    # HTTP retry may resend a served proof), so {PowGate#enforce} skips it
    # without penalty; if the quota then goes unmet the request gets a fresh
    # `Errors::PowRequired` re-challenge (402) — never `Errors::Forbidden`.
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
    #   claim(id, exp)      → Boolean  (ATOMIC: true iff THIS caller claimed it;
    #                                   false if already claimed — the single-use
    #                                   gate, called BEFORE the expensive verify)
    #   release(id)         → void     (undo a claim that turned out unspendable)
    #   spent?(id)          → Boolean  (read-only membership; not on the hot path)
    #   mark_spent(id, exp) → void     (idempotent set — retained for overrides)
    class PowSpentStore
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      # Atomically claim +id+ as spent until Unix timestamp +exp+, returning
      # true iff THIS caller made the claim (the id was not already present).
      #
      # This is the single-use guard for PoW proofs and MUST be called BEFORE
      # the (expensive) proof verify: of N submitters racing the SAME valid
      # proof id, exactly one wins the claim and proceeds to verify; the losers
      # get false and treat it as a replay (K-542). Because the claim precedes
      # the verify, a bad proof's id is also consumed by the claim it already
      # won, so one issued challenge cannot fuel unlimited garbage verifies
      # (K-540).
      #
      # A shared multi-process override MUST implement this as ONE atomic op —
      # Redis `SET id <v> NX EX <ttl>` (SETNX), or SQL
      # `INSERT INTO pow_spent (id, exp) VALUES ($1,$2) ON CONFLICT (id) DO
      # NOTHING` and return whether a row was inserted — NOT a read-then-write,
      # which reintroduces the very TOCTOU this method closes.
      #
      # @param id  [String, nil]
      # @param exp [Integer] Unix timestamp at or after which the entry is stale
      # @return [Boolean] true if claimed here, false if already claimed
      def claim(id, exp)
        return false if id.nil?

        prune!
        @mutex.synchronize do
          if @store.key?(id)
            false
          else
            @store[id] = exp
            true
          end
        end
      end

      # Release a previously-claimed +id+ (compensating op). Used when a claim
      # cannot be spent after all — an honest-skew / forged-sig proof that failed
      # the cheap checks, or an N-proof partial submission that did not meet the
      # quota — so a legitimate retry is not blocked by our own claim. A shared
      # override implements this as Redis `DEL` / SQL `DELETE`.
      # @param id [String, nil]
      def release(id)
        return if id.nil?

        @mutex.synchronize { @store.delete(id) }
      end

      # @param id [String, nil] the challenge id to check
      # @return [Boolean]
      def spent?(id)
        return false if id.nil?

        prune!
        @mutex.synchronize { @store.key?(id) }
      end

      # Mark +id+ as spent until Unix timestamp +exp+. Idempotent set (no
      # claim semantics) — retained for external overrides and read-side tests;
      # the gate itself now uses the atomic {#claim}.
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
