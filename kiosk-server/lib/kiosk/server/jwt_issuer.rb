# frozen_string_literal: true

require "jwt"
require "securerandom"

module Kiosk
  module Server
    # Sign and verify JWTs using the configured {SigningKey}.
    #
    # Two roles:
    #
    #   - **Issuer role.** {.issue} produces a JWS-signed JWT (RS256) with
    #     the standard time-bound claims (`iss`, `aud`, `iat`, `exp`,
    #     `nbf`, `jti`). The `kid` header points at the signing key's
    #     RFC 7638 thumbprint, so verifiers fetching the JWKS can pick the
    #     right key during a rotation overlap.
    #
    #   - **Verifier role.** {.verify} validates signature + lifetime +
    #     audience against the supplied JWKS. Returns the claims hash on
    #     success; raises a {Error} subclass on failure.
    #
    # Used by the OAuth surface to issue access tokens, by the
    # bundled IdP for direct token issuance, and by AP2 mandate
    # validation for cross-server signature checks.
    module JwtIssuer
      # Algorithm advertised in the JWS header. Pinned to RS256 — the
      # OAuth-ecosystem baseline and the only algorithm our SigningKey
      # supports today. To migrate to EdDSA later, ship the new alg in
      # parallel during a JWKS rotation overlap.
      ALGORITHM = "RS256"

      # Default token lifetime when the caller doesn't override.
      # Short enough that revocation latency stays bounded; long enough
      # that a typical agent session doesn't refresh every few minutes.
      DEFAULT_EXPIRES_IN = 3600 # 1 hour

      # Issued-at clock skew tolerance for the `nbf`/`iat`/`exp` checks
      # on the verifier side. Default mirrors the AWS / Google ID-token
      # ecosystems' ±60s convention.
      DEFAULT_LEEWAY = 60

      # ─── Errors ───────────────────────────────────────────────────────

      # Base class for all JWT-verification failures.
      class Error < StandardError; end

      # Token's signature does not match any key in the supplied JWKS.
      class SignatureError < Error; end

      # Token is past `exp` (taking leeway into account).
      class ExpiredError < Error; end

      # Token's `aud` claim does not match the expected audience.
      class AudienceError < Error; end

      # Token is malformed, missing required claims, or otherwise rejected
      # before the cryptographic check.
      class InvalidError < Error; end

      # Token's signature and lifetime are valid, but the agent's revocation
      # watermark covers its `iat` — it was invalidated by `/auth/revoke`
      # ("log out other sessions"). A subclass of {Error}, so every IdP that
      # already rescues {Error} → nil (→ 401) treats a revoked token exactly
      # like any other failed verification.
      class RevokedError < Error; end

      module_function

      # Issue a signed JWT.
      #
      # @param claims [Hash] user-supplied payload claims (subject,
      #   custom claims, role, scope, etc.). Reserved claims set by this
      #   method (`iat`, `nbf`, `exp`, `iss`, `aud`) override any
      #   collision in `claims`.
      # @param signing_key [SigningKey] key whose private half signs the
      #   token. Defaults to `Kiosk.configuration.signing_key`.
      # @param issuer [String] value for the `iss` claim. Defaults to
      #   `Kiosk.configuration.issuer`.
      # @param audience [String, Array<String>] value for the `aud` claim.
      #   Required — every Kiosk-issued token is bound to an audience.
      # @param expires_in [Integer] lifetime in seconds. Default
      #   {DEFAULT_EXPIRES_IN}.
      # @param now [Time] override clock (for tests).
      # @return [String] compact-serialised JWS.
      def issue(claims:, audience:, signing_key: nil, issuer: nil, expires_in: DEFAULT_EXPIRES_IN, now: Time.now)
        signing_key ||= Kiosk.configuration.signing_key
        issuer      ||= Kiosk.configuration.issuer
        raise ArgumentError, "issuer is required (set Kiosk.configuration.issuer or pass :issuer)" if issuer.nil? || issuer.empty?
        raise ArgumentError, "signing_key must carry a private key for issuance" unless signing_key.private?

        payload = claims.dup
        payload[:iat] = now.to_i
        payload[:nbf] = now.to_i
        payload[:exp] = now.to_i + expires_in
        payload[:iss] = issuer
        payload[:aud] = audience
        payload[:jti] ||= SecureRandom.uuid

        ::JWT.encode(
          payload,
          signing_key.rsa,
          ALGORITHM,
          { kid: signing_key.kid, typ: "JWT" },
        )
      end

      # Verify a JWT against a JWKS.
      #
      # @param token [String] compact-serialised JWS.
      # @param jwks [Hash, Array<SigningKey>] either a JWKS document
      #   (`{ keys: [...] }`) or an array of {SigningKey} instances.
      # @param audience [String, Array<String>] expected `aud` value.
      # @param issuer [String] expected `iss` value; if nil, the claim is
      #   accepted as-is (no equality check).
      # @param leeway [Integer] clock-skew window in seconds. Default
      #   {DEFAULT_LEEWAY}.
      # @param revocation_store [#revoked?, nil] consulted after the
      #   cryptographic check to reject tokens invalidated by `/auth/revoke`.
      #   Defaults to `Kiosk.configuration.revocation_store` (so every IdP that
      #   calls this method gets revocation enforcement for free); pass `nil` to
      #   skip the check entirely.
      # @return [Hash] verified claims (symbolised keys).
      # @raise [Error] on any verification failure (subclass indicates
      #   which check rejected the token).
      def verify(token:, jwks:, audience: nil, issuer: nil, leeway: DEFAULT_LEEWAY,
                 revocation_store: :from_config)
        jwks_doc = normalize_jwks(jwks)

        decoded, = ::JWT.decode(
          token,
          nil,
          true,
          jwks:       jwks_doc,
          algorithms: [ALGORITHM],
          aud:        audience,
          iss:        issuer,
          verify_aud: !audience.nil?,
          verify_iss: !issuer.nil?,
          leeway:     leeway,
        )

        claims = symbolize(decoded)

        store = revocation_store == :from_config ? configured_revocation_store : revocation_store
        if store && store.revoked?(agent_id: claims[:agent_id], iat: claims[:iat])
          raise RevokedError, "access token revoked"
        end

        claims
      rescue ::JWT::ExpiredSignature => e
        raise ExpiredError, e.message
      rescue ::JWT::InvalidAudError => e
        raise AudienceError, e.message
      rescue ::JWT::VerificationError, ::JWT::IncorrectAlgorithm => e
        raise SignatureError, e.message
      rescue ::JWT::DecodeError => e
        # "Could not find public key for kid …" — token claims a key not
        # in our JWKS, so signature can't be verified. Semantically
        # closer to SignatureError than to a malformed-token error.
        if e.message.include?("public key for kid") || e.message.include?("Could not find public key")
          raise SignatureError, e.message
        end
        raise InvalidError, e.message
      end

      # ─── Helpers ──────────────────────────────────────────────────────

      def normalize_jwks(input)
        case input
        when Hash
          input
        when Array
          { keys: input.map { |sk| sk.is_a?(SigningKey) ? sk.to_jwk : sk } }
        when SigningKey
          { keys: [input.to_jwk] }
        else
          raise ArgumentError, "jwks must be a Hash, Array, or SigningKey, got #{input.class}"
        end
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
      end

      # The configured revocation store, or nil when the host has no server
      # ConfigurationExtension loaded / has explicitly disabled revocation.
      # Isolated so `verify` stays a pure function unless a store is present.
      def configured_revocation_store
        cfg = Kiosk.configuration
        cfg.respond_to?(:revocation_store) ? cfg.revocation_store : nil
      rescue StandardError
        nil
      end
    end
  end
end
