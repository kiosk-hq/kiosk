# frozen_string_literal: true

require "jwt"
require "openssl"
require "rails"

module Kiosk
  module Server
    # Verifies an agent's proof-of-possession JWS: RS256 by the presented key,
    # `aud` equal to this origin (the relay defence), and the challenge `nonce`.
    # The caller burns the nonce only after a clean verify.
    module PopVerifier
      # Names no origin: an echoed one is what a relaying server would exploit.
      AUDIENCE_HINT =
        "sign `aud` = the origin you connected to, taken from your own request " \
        "URL — never from a value echoed back in a response"

      PROOF_REQUIRED_CLAIMS = %w[aud nonce jti].freeze

      PROOF_CLAIMS_HINT =
        "a proof's payload carries #{PROOF_REQUIRED_CLAIMS.join(", ")} — `aud` is the origin " \
        "you connected to, `nonce` the value GET /auth/challenge just issued for this key, " \
        "`jti` a unique id for this proof"

      PROOF_SIGNATURE_HINT =
        "a proof is a compact RS256 JWS — header.payload.signature — signed with the " \
        "private key matching the public_key you sent"

      module_function

      def verify!(public_key_pem:, signed:)
        pem = public_key_pem.to_s.strip
        key = load_public_key(pem)

        payload, = ::JWT.decode(
          signed.to_s, key, true,
          algorithms: ["RS256"], required_claims: PROOF_REQUIRED_CLAIMS,
        )
        payload = payload.transform_keys(&:to_sym)

        issuer = Kiosk.current_issuer
        unless payload[:aud] == issuer
          log_audience_mismatch(signed_aud: payload[:aud], issuer: issuer)
          raise Errors::Unauthenticated.new("proof audience mismatch", hint: AUDIENCE_HINT)
        end

        if payload.key?(:pub) && payload[:pub] != SigningKey.from_pem(pem).kid
          raise Errors::Unauthenticated.new("proof key thumbprint mismatch")
        end

        payload
      rescue ::JWT::MissingRequiredClaim
        raise Errors::Unauthenticated.new("proof is missing a required claim", hint: PROOF_CLAIMS_HINT)
      rescue ::JWT::DecodeError
        raise Errors::Unauthenticated.new("proof signature invalid", hint: PROOF_SIGNATURE_HINT)
      end

      # Operator log only, since the response must not name an origin: the
      # caller signed a wrong value, or the origin it reached is not served.
      def log_audience_mismatch(signed_aud:, issuer:)
        message = "[kiosk] PoP audience mismatch: caller signed aud=#{signed_aud.inspect}, " \
                  "the issuer for this request is #{issuer.inspect}. If the signed value is " \
                  "an origin your assistants actually reach, list it in `c.issuer` or " \
                  "`c.additional_origins`."
        logger = ::Rails.logger
        logger ? logger.warn(message) : warn(message)
      end

      # Also the key floor of account binding.
      def load_public_key(pem)
        rsa = OpenSSL::PKey::RSA.new(pem)
        if rsa.n.num_bits < SigningKey::MIN_KEY_BITS
          raise Errors::BadRequest.new(
            "public key too small (#{rsa.n.num_bits} bits; minimum #{SigningKey::MIN_KEY_BITS})",
          )
        end
        rsa
      rescue OpenSSL::PKey::PKeyError
        raise Errors::BadRequest.new(
          "invalid public key",
          hint: "send a PEM-encoded RSA public key of at least " \
                "#{SigningKey::MIN_KEY_BITS} bits (-----BEGIN PUBLIC KEY----- …)",
        )
      end
    end
  end
end
