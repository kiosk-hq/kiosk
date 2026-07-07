# frozen_string_literal: true

require "securerandom"

module Kiosk
  module Server
    # Server side of the PoP challenge-response handshake.
    #
    # {.issue} mints a fresh single-use nonce for a public key and records it in
    # the configured {AuthChallengeStore} with a short TTL. {.consume!} verifies
    # and burns it, raising {Errors::Unauthenticated} when no live challenge
    # matches (stale, already-spent, or never issued).
    module AuthChallenge
      module_function

      # @return [Hash] { challenge:, exp: } — `challenge` is the nonce the agent
      #   must echo inside its signed JWS; `exp` is the Unix expiry.
      def issue(public_key_pem:, now: Time.now)
        config = Kiosk.configuration
        nonce  = SecureRandom.urlsafe_base64(32)
        exp    = now.to_i + config.auth_challenge_ttl
        config.auth_challenge_store.put(public_key_pem.to_s.strip, nonce, exp)
        { challenge: nonce, exp: exp }
      end

      # Burn the outstanding challenge for +public_key_pem+ matching +nonce+.
      # Single-use: a matched challenge is deleted so it can never be replayed.
      #
      # @raise [Errors::Unauthenticated] if no live, matching challenge exists.
      def consume!(public_key_pem:, nonce:)
        ok = Kiosk.configuration.auth_challenge_store.take(public_key_pem.to_s.strip, nonce.to_s)
        return true if ok

        raise Errors::Unauthenticated.new(
          "no matching auth challenge",
          hint: "GET /auth/challenge?public_key=… first, then sign the returned nonce; " \
                "challenges are single-use and short-lived",
        )
      end
    end
  end
end
