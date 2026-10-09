# frozen_string_literal: true

require "securerandom"

module Kiosk
  module Server
    # Server side of the proof-of-possession challenge: a single-use, short-lived
    # nonce per public key.
    module AuthChallenge
      module_function

      # The agent signs `challenge` into its JWS; `exp` is the Unix expiry.
      def issue(public_key_pem:, now: Time.now)
        config = Kiosk.configuration
        nonce  = SecureRandom.urlsafe_base64(32)
        exp    = now.to_i + config.auth_challenge_ttl
        config.auth_challenge_store.put(public_key_pem.to_s.strip, nonce, exp)
        { challenge: nonce, exp: exp }
      end

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
