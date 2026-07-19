# frozen_string_literal: true

require "openssl"
require "base64"
require "digest"
require "json"

module Kiosk
  module Server
    # RSA signing-key value object used by {JwtIssuer} and the bundled
    # agent-IdP to sign/verify the JWTs the kiosk-pop auth surface issues
    # (including the account-binding ceremony's token poll),
    # and to publish the public half as JWKS.
    #
    # Wraps an `OpenSSL::PKey::RSA` instance and exposes the derived
    # JWK shape and RFC 7638 thumbprint as cached attributes. The same key
    # signs every JWT issued by this deployment until rotated; rotation is
    # handled by reassigning {Kiosk.configuration.signing_key}.
    #
    # @example Generate a fresh key (dev / first-run)
    #   key = Kiosk::Server::SigningKey.generate
    #
    # @example Load from PEM (production)
    #   key = Kiosk::Server::SigningKey.from_pem(ENV.fetch("KIOSK_SIGNING_KEY_PEM"))
    #
    # @example JWK for inclusion in JWKS
    #   key.to_jwk # => { kty:, use:, alg:, kid:, n:, e: }
    class SigningKey
      # Minimum RSA modulus length we generate or accept. RS256 with shorter
      # keys is deprecated; OpenID providers in 2026 universally target ≥2048.
      MIN_KEY_BITS = 2048

      # JWS algorithm advertised in the JWK `alg` field. RS256 is the
      # OAuth-ecosystem baseline (Apple Sign In, Auth0, Microsoft Entra…).
      ALGORITHM = "RS256"

      # @return [OpenSSL::PKey::RSA] the underlying keypair (includes
      #   the private component when locally generated or loaded from PEM
      #   that contained one).
      attr_reader :rsa

      # @param rsa [OpenSSL::PKey::RSA]
      # @raise [ArgumentError] if `rsa` is not an RSA key or is shorter than
      #   {MIN_KEY_BITS}.
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

      # Generate a fresh RSA 2048 keypair. Useful for dev / first-run; in
      # production load from a PEM held in secrets management.
      def self.generate(bits: MIN_KEY_BITS)
        new(OpenSSL::PKey::RSA.generate(bits))
      end

      # Load a key from PEM-encoded bytes. Accepts either a public-only PEM
      # (verifier role) or a full keypair (issuer role).
      def self.from_pem(pem)
        new(OpenSSL::PKey::RSA.new(pem))
      end

      # @return [OpenSSL::PKey::RSA] a public-only view of the key, suitable
      #   for distributing to verifiers.
      def public_key
        rsa.public_key
      end

      # @return [Boolean] true when this instance carries the private half
      #   (and can therefore sign).
      def private?
        rsa.private?
      end

      # @return [String] PEM serialisation of the private key. Raises if the
      #   instance is public-only.
      def to_pem
        raise "cannot export PEM: signing key is public-only" unless private?
        rsa.to_pem
      end

      # RFC 7638 JWK thumbprint — stable identifier derived from the
      # canonical-JSON of the required JWK members. We use it as the JWK
      # `kid` so verifiers can match a JWT's `kid` header to a JWKS entry
      # without coordinating IDs out of band.
      def kid
        @kid ||= compute_thumbprint
      end

      # JWK shape per RFC 7517 §4. RSA public key with the advertised use
      # and algorithm. Private parameters are never included.
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
        # RFC 7638 §3.2: required members for RSA are e, kty, n, in
        # alphabetical order with no whitespace.
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
