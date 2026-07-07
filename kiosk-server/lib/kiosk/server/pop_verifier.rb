# frozen_string_literal: true

require "jwt"
require "openssl"

module Kiosk
  module Server
    # Verifies an agent's proof-of-possession JWS for the auth handshake.
    #
    # A public key proves nothing on its own — it is public. The agent proves
    # control of the matching PRIVATE key by signing a compact RS256 JWS whose
    # payload carries:
    #
    #   aud   — the origin the agent actually dialed. MUST equal this provider's
    #           issuer/origin. This is the relay defense: a signature produced
    #           for provider M cannot be replayed at provider L, because L checks
    #           aud == L. Same audience-binding principle as the mandate `iss`
    #           guard (see {MandateVerifier}); modelled on WebAuthn origin
    #           binding — the agent binds the origin IT connected to, not one
    #           echoed back by the server.
    #   nonce — the single-use challenge from GET /auth/challenge. Freshness +
    #           anti-replay; bound to this key by {AuthChallengeStore}.
    #   pub   — RFC 7638 thumbprint of the presented public key (binds the proof
    #           to this exact key). Optional but verified when present.
    #   jti   — unique id.
    #
    # Returns the symbol-keyed payload on success; raises an {Errors::Base}
    # subclass otherwise. Does NOT touch the challenge store — the caller burns
    # the nonce via {AuthChallenge.consume!} only after a clean verify.
    module PopVerifier
      module_function

      def verify!(public_key_pem:, signed:)
        pem = public_key_pem.to_s.strip
        key = load_public_key(pem)

        payload, = ::JWT.decode(
          signed.to_s, key, true,
          algorithms: ["RS256"], required_claims: %w[aud nonce jti],
        )
        payload = payload.transform_keys(&:to_sym)

        issuer = Kiosk.configuration.issuer
        unless payload[:aud] == issuer
          raise Errors::Unauthenticated.new(
            "proof audience mismatch",
            hint: "sign `aud` = the origin you connected to (this provider is #{issuer.inspect})",
          )
        end

        if payload.key?(:pub) && payload[:pub] != SigningKey.from_pem(pem).kid
          raise Errors::Unauthenticated.new("proof key thumbprint mismatch")
        end

        payload
      rescue ::JWT::MissingRequiredClaim => e
        raise Errors::Unauthenticated.new("proof missing claim: #{e.message}")
      rescue ::JWT::DecodeError => e
        raise Errors::Unauthenticated.new("proof signature invalid: #{e.message}")
      end

      # Parse the presented public key, rejecting anything that isn't a usable
      # RSA-2048+ public key with a clear client error rather than a raw crash.
      def load_public_key(pem)
        rsa = OpenSSL::PKey::RSA.new(pem)
        if rsa.n.num_bits < SigningKey::MIN_KEY_BITS
          raise Errors::BadRequest.new(
            "public key too small (#{rsa.n.num_bits} bits; minimum #{SigningKey::MIN_KEY_BITS})",
          )
        end
        rsa
      rescue OpenSSL::PKey::PKeyError => e
        raise Errors::BadRequest.new("invalid public key: #{e.message}")
      end
      private_class_method :load_public_key
    end
  end
end
