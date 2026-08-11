# frozen_string_literal: true

require "jwt"
require "openssl"
require "rails" # Rails.logger, in #log_audience_mismatch

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
      # Hint on the 401 raised for an audience mismatch (K-511).
      #
      # It names NO origin — not the configured issuer, not any other host.
      # The previous wording appended "(this provider is <issuer>)", which
      # handed the caller a concrete `aud` value read out of a RESPONSE. That
      # is the exact move the audience binding exists to stop: a hostile server
      # could answer any handshake with "(this provider is <bank>)", and a
      # helpful agent would sign a fresh PoP for <bank> with its own key and
      # post it back — a signature the hostile server then replays at <bank>'s
      # /auth/login for full account takeover. Echoing an origin the caller did
      # not dial is only ever safe when it equals the origin the caller dialed,
      # and this module cannot observe that (see {.log_audience_mismatch}), so
      # it echoes nothing at all. The agent already knows the one correct
      # value: the origin it typed into its own request URL.
      AUDIENCE_HINT =
        "sign `aud` = the origin you connected to, taken from your own request " \
        "URL — never from a value echoed back in a response"

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
          log_audience_mismatch(signed_aud: payload[:aud], issuer: issuer)
          raise Errors::Unauthenticated.new("proof audience mismatch", hint: AUDIENCE_HINT)
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

      # Operator-side diagnostic for an audience mismatch (K-511 half two).
      #
      # The mismatch has two very different causes and only the OPERATOR can
      # tell them apart:
      #
      #   * the caller signed the wrong value (its bug — the wire hint covers it), or
      #   * `c.issuer` does not match the host this instance is actually served
      #     on (the operator's bug — K-510: every demo defaults the issuer to
      #     localhost, so one missing KIOSK_ISSUER rejects every real assistant).
      #
      # A run of these lines where the SIGNED aud is the host your users reach
      # is the second case. This goes to the operator's log and never onto the
      # wire — the response must not name an origin (see {AUDIENCE_HINT}).
      #
      # This module is a pure verifier called from the registration, login,
      # link-claim and device-grant paths, none of which carry the Rack request,
      # so it cannot compare the issuer against the actual request origin
      # without widening four service-object signatures. It logs what it can
      # see — the signed aud — which is the same signal.
      def log_audience_mismatch(signed_aud:, issuer:)
        message = "[kiosk] PoP audience mismatch: caller signed aud=#{signed_aud.inspect}, " \
                  "this instance's configured issuer is #{issuer.inspect}. If the signed " \
                  "value is the origin your assistants actually reach, `c.issuer` is wrong."
        # Rails.logger is nil until the host app boots (rake tasks, console
        # helpers, the gem's own specs), so keep the Kernel#warn fallback.
        logger = ::Rails.logger
        logger ? logger.warn(message) : warn(message)
      end

      # Parse the presented public key, rejecting anything that isn't a usable
      # RSA-2048+ public key with a clear client error rather than a raw crash.
      # Public: the account-binding surface (POST /oauth/device_authorization,
      # POST /auth/claim) reuses this exact check so the key floor cannot
      # drift between registration and binding.
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
    end
  end
end
