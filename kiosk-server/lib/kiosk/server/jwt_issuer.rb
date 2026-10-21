# frozen_string_literal: true

require 'jwt'
require 'securerandom'

module Kiosk
  module Server
    # Issues and verifies the RS256 access tokens of the bundled agent IdP.
    module JwtIssuer
      ALGORITHM = 'RS256'
      DEFAULT_EXPIRES_IN = 3600
      DEFAULT_LEEWAY = 60

      # A `kid` not in the JWKS: the signature cannot be checked.
      UNKNOWN_KID = ->(e) { e.message.include?('public key for kid') || e.message.include?('Could not find public key') }
      private_constant :UNKNOWN_KID

      class Error < StandardError; end
      class SignatureError < Error; end
      class ExpiredError < Error; end
      class AudienceError < Error; end
      class InvalidError < Error; end
      # The agent's revocation watermark covers the token's `iat`.
      class RevokedError < Error; end

      module_function

      # rubocop:disable-next Metrics/ParameterLists -- a keyword-only public API; callers pass each option by name
      def issue(claims:, audience:, signing_key: nil, issuer: nil, expires_in: DEFAULT_EXPIRES_IN, now: Time.current)
        signing_key ||= Kiosk.configuration.signing_key
        issuer      ||= Kiosk.current_issuer
        raise ArgumentError, 'issuer is required (set Kiosk.configuration.issuer or pass :issuer)' if issuer.blank?
        raise ArgumentError, 'signing_key must carry a private key for issuance' unless signing_key.private?

        payload = registered_claims(claims, issuer: issuer, audience: audience, issued_at: now.to_i, expires_in: expires_in)
        ::JWT.encode(payload, signing_key.rsa, ALGORITHM, { kid: signing_key.kid, typ: 'JWT' })
      end

      def verify(token:, jwks:, audience: nil, issuer: nil, leeway: DEFAULT_LEEWAY)
        claims = decode(token, normalize_jwks(jwks), audience: audience, issuer: issuer, leeway: leeway)
        revoked = Kiosk.configuration.revocation_store.revoked?(agent_id: claims[:agent_id], iat: claims[:iat])
        raise RevokedError, 'access token revoked' if revoked

        claims
      end

      def registered_claims(claims, issuer:, audience:, issued_at:, expires_in:)
        payload = claims.dup
        payload[:iat] = issued_at
        payload[:nbf] = issued_at
        payload[:exp] = issued_at + expires_in
        payload[:iss] = issuer
        payload[:aud] = audience
        payload[:jti] ||= SecureRandom.uuid
        payload
      end

      def decode(token, jwks, audience:, issuer:, leeway:)
        decoded, = ::JWT.decode(
          token, nil, true,
          jwks: jwks, algorithms: [ALGORITHM], aud: audience, iss: issuer,
          verify_aud: !audience.nil?, verify_iss: !issuer.nil?, leeway: leeway
        )
        symbolize(decoded)
      rescue ::JWT::DecodeError => e
        raise error_class_for(e), e.message
      end

      def error_class_for(error)
        case error
        when ::JWT::ExpiredSignature then ExpiredError
        when ::JWT::InvalidAudError then AudienceError
        when ::JWT::VerificationError, ::JWT::IncorrectAlgorithm, UNKNOWN_KID then SignatureError
        else InvalidError
        end
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

      def symbolize(hash) = hash.deep_symbolize_keys

      private_class_method :registered_claims, :decode, :error_class_for
    end
  end
end
