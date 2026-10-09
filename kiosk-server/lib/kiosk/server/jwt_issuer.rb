# frozen_string_literal: true

require "jwt"
require "securerandom"

module Kiosk
  module Server
    # Issues and verifies the RS256 access tokens of the bundled kiosk-pop IdP.
    module JwtIssuer
      ALGORITHM = "RS256"
      DEFAULT_EXPIRES_IN = 3600
      DEFAULT_LEEWAY = 60

      class Error < StandardError; end
      class SignatureError < Error; end
      class ExpiredError < Error; end
      class AudienceError < Error; end
      class InvalidError < Error; end
      # The agent's revocation watermark covers the token's `iat`.
      class RevokedError < Error; end

      module_function

      def issue(claims:, audience:, signing_key: nil, issuer: nil, expires_in: DEFAULT_EXPIRES_IN, now: Time.now)
        signing_key ||= Kiosk.configuration.signing_key
        issuer      ||= Kiosk.current_issuer
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

      # `revocation_store: nil` skips the revocation check.
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
        # A `kid` not in the JWKS: the signature cannot be checked.
        if e.message.include?("public key for kid") || e.message.include?("Could not find public key")
          raise SignatureError, e.message
        end
        raise InvalidError, e.message
      end

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

      def configured_revocation_store
        cfg = Kiosk.configuration
        cfg.respond_to?(:revocation_store) ? cfg.revocation_store : nil
      rescue StandardError
        nil
      end
    end
  end
end
