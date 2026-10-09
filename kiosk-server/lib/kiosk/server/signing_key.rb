# frozen_string_literal: true

require "openssl"
require "base64"
require "digest"
require "json"

module Kiosk
  module Server
    # The RSA key that signs this deployment's JWTs, and its public JWK.
    class SigningKey
      MIN_KEY_BITS = 2048

      ALGORITHM = "RS256"

      attr_reader :rsa

      def initialize(rsa)
        unless rsa.is_a?(OpenSSL::PKey::RSA)
          raise ArgumentError, "expected OpenSSL::PKey::RSA, got #{rsa.class}"
        end
        if rsa.n.num_bits < MIN_KEY_BITS
          raise ArgumentError,
            "RSA key is #{rsa.n.num_bits} bits; minimum is #{MIN_KEY_BITS}"
        end
        @rsa = rsa
      end

      def self.generate(bits: MIN_KEY_BITS)
        new(OpenSSL::PKey::RSA.generate(bits))
      end

      # A public-only PEM verifies; a full keypair also signs.
      def self.from_pem(pem)
        new(OpenSSL::PKey::RSA.new(pem))
      end

      def public_key
        rsa.public_key
      end

      def private?
        rsa.private?
      end

      def to_pem
        raise "cannot export PEM: signing key is public-only" unless private?
        rsa.to_pem
      end

      # The RFC 7638 thumbprint.
      def kid
        @kid ||= compute_thumbprint
      end

      # RFC 7517 §4; never the private parameters.
      def to_jwk
        {
          kty: "RSA",
          use: "sig",
          alg: ALGORITHM,
          kid: kid,
          n:   b64url(rsa.n.to_s(2)),
          e:   b64url(rsa.e.to_s(2)),
        }
      end

      private

      def compute_thumbprint
        # RFC 7638 §3.2: the required members, in alphabetical order.
        canonical = JSON.generate(
          {
            e:   b64url(rsa.e.to_s(2)),
            kty: "RSA",
            n:   b64url(rsa.n.to_s(2)),
          },
        )
        b64url(Digest::SHA256.digest(canonical))
      end

      def b64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end
    end
  end
end
