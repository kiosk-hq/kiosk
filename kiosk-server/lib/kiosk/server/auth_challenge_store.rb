# frozen_string_literal: true

require "openssl"

module Kiosk
  module Server
    # In-process TTL store binding a public key to its outstanding, single-use
    # auth challenge nonce (the server side of the PoP challenge-response).
    #
    # `GET /auth/challenge` calls {#put}; `POST /auth/{register,login}` calls
    # {#take}, which succeeds at most once per issued challenge — a matched
    # nonce is deleted so it can never be replayed.
    #
    # Mirrors {PowSpentStore}: Mutex-guarded, pruned opportunistically, and NOT
    # shared across web workers. Multi-process providers MUST override
    # `Kiosk.configure { |c| c.auth_challenge_store = MyRedisChallengeStore.new }`.
    # The interface contract is:
    #
    #   put(public_key_pem, nonce, exp) → void    (exp is a Unix timestamp)
    #   take(public_key_pem, nonce)     → Boolean  (true iff a live, matching
    #                                     challenge existed; consumes it)
    class AuthChallengeStore
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      # Record +nonce+ as the outstanding challenge for +public_key_pem+ until
      # Unix timestamp +exp+. Overwrites any prior challenge for the same key —
      # only the most recently issued challenge is valid.
      #
      # Prunes expired entries opportunistically on the way in: a
      # distinct-key challenge flood — GET /auth/challenge is unauthenticated —
      # cannot accumulate unboundedly, since each insert first drops every
      # already-expired entry. Without this, expired entries only cleared when a
      # later #take ran, which never happens for keys that never register.
      def put(public_key_pem, nonce, exp)
        prune!
        @mutex.synchronize { @store[public_key_pem] = [nonce, exp] }
      end

      # Consume the challenge for +public_key_pem+ iff one exists, matches
      # +nonce+, and has not expired. Single-use: a successful match deletes the
      # entry.
      #
      # @return [Boolean]
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

      # Drop every challenge whose exp has passed. Called automatically by
      # {#put} before each insert and by {#take} before each look-up, so
      # expired entries never accumulate.
      def prune!
        now = Time.now.to_i
        @mutex.synchronize { @store.reject! { |_, (_, exp)| exp <= now } }
      end

      private

      # Constant-time nonce comparison — a challenge nonce is a bearer secret
      # for the duration of the handshake, so avoid leaking it through timing.
      def constant_time_eq?(a, b)
        return false if a.nil? || b.nil? || a.bytesize != b.bytesize

        OpenSSL.fixed_length_secure_compare(a, b)
      end
    end
  end
end
