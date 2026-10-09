# frozen_string_literal: true

require "openssl"

module Kiosk
  module Server
    # In-process store of each public key's outstanding challenge nonce. Not
    # shared across workers: a multi-process origin sets
    # `c.auth_challenge_store = AuthChallengeStores::ActiveRecord.new`.
    #
    #   put(public_key_pem, nonce, exp) → void     (exp is a Unix timestamp)
    #   take(public_key_pem, nonce)     → Boolean  (consumes a live, matching challenge)
    class AuthChallengeStore
      # Bounds memory under an unauthenticated flood of live challenges.
      DEFAULT_MAX_ENTRIES = 50_000

      def initialize(max_entries: DEFAULT_MAX_ENTRIES)
        @store       = {}
        @mutex       = Mutex.new
        @max_entries = Integer(max_entries)
        raise ArgumentError, "max_entries must be positive" if @max_entries < 1
      end

      # Replaces any earlier challenge for the key; evicts the oldest at capacity.
      def put(public_key_pem, nonce, exp)
        prune!
        @mutex.synchronize do
          @store.delete(public_key_pem)          # move-to-newest on re-issue
          @store.shift while @store.size >= @max_entries # evict oldest at capacity
          @store[public_key_pem] = [nonce, exp]
        end
      end

      def take(public_key_pem, nonce)
        prune!
        now = Time.now.to_i
        @mutex.synchronize do
          stored = @store[public_key_pem]
          next false if stored.nil?

          got_nonce, exp = stored
          next false if exp <= now
          next false unless constant_time_eq?(got_nonce, nonce)

          @store.delete(public_key_pem)
          true
        end
      end

      def prune!
        now = Time.now.to_i
        @mutex.synchronize { @store.reject! { |_, (_, exp)| exp <= now } }
      end

      private

      def constant_time_eq?(a, b)
        return false if a.nil? || b.nil? || a.bytesize != b.bytesize

        OpenSSL.fixed_length_secure_compare(a, b)
      end
    end
  end
end
