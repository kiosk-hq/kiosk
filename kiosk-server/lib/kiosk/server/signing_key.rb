# frozen_string_literal: true

require 'openssl'

module Kiosk
  module Server
    # The Ed25519 key that signs this deployment's JWTs (EdDSA, RFC 8037): its
    # access tokens, checkouts and receipts. Its public JWK names `alg` EdDSA.
    class SigningKey
      HINT = 'generate one with `openssl genpkey -algorithm ed25519`'

      attr_reader :key

      def initialize(key)
        raise ArgumentError, "the signing key is an Ed25519 key, got #{key.class}; #{HINT}" unless Jwk.ed25519?(key)

        @key = key
      end

      def self.generate
        new(OpenSSL::PKey.generate_key('ED25519'))
      end

      # A public-only PEM verifies; a private PEM also signs.
      def self.from_pem(pem)
        new(OpenSSL::PKey.read(pem))
      rescue OpenSSL::PKey::PKeyError
        raise ArgumentError, "the signing key is not a PEM key; #{HINT}"
      end

      def private? = Jwk.private?(key)

      def to_pem
        raise 'cannot export PEM: signing key is public-only' unless private?

        key.private_to_pem
      end

      # The RFC 7638 thumbprint.
      def kid
        @kid ||= Jwk.thumbprint(key)
      end

      # RFC 7517 §4; never the private member.
      def to_jwk = { **Jwk.public_members(key), use: 'sig', alg: Eddsa::NAME, kid: kid }
    end
  end
end
