# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'jwt'
require 'openssl'

module Kiosk
  module Server
    # The public keys Kiosk signs and verifies with, as OpenSSL keys and as
    # JWKs: Ed25519 (RFC 8037, `kty` OKP, algorithm EdDSA) and P-256 (RFC 7518,
    # `kty` EC, algorithm ES256).
    module Jwk
      # The JOSE algorithm of each key type.
      ALGORITHMS = { 'OKP' => 'EdDSA', 'EC' => 'ES256' }.freeze

      # The curve of each key type.
      CURVES = { 'OKP' => 'Ed25519', 'EC' => 'P-256' }.freeze

      module_function

      def ed25519?(key) = key.is_a?(OpenSSL::PKey::PKey) && key.oid == 'ED25519'

      def p256?(key) = key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == 'prime256v1'

      # OpenSSL answers `private?` for an EC key only.
      def private?(key)
        return key.private? if key.is_a?(OpenSSL::PKey::EC)

        key.raw_private_key
        true
      rescue OpenSSL::PKey::PKeyError
        false
      end

      # `OKP`, `EC`, or nil for a key Kiosk does not use.
      def kty(key)
        if ed25519?(key) then 'OKP'
        elsif p256?(key) then 'EC'
        end
      end

      # The JOSE algorithm that `key` signs with, or nil.
      def algorithm(key) = ALGORITHMS[kty(key)]

      # The public members of `key`: the RFC 7638 required members.
      def public_members(key)
        case kty(key)
        when 'OKP' then { crv: CURVES['OKP'], kty: 'OKP', x: b64(key.raw_public_key) }
        when 'EC'
          point = key.public_key.to_bn(:uncompressed).to_s(2)
          { crv: CURVES['EC'], kty: 'EC', x: b64(point[1, 32]), y: b64(point[33, 32]) }
        else raise ArgumentError, "Kiosk uses Ed25519 and P-256 keys, got #{key.class}"
        end
      end

      # The public key of a JWK with the public members of its `kty`.
      # @raise [ArgumentError] when the JWK is not an Ed25519 or a P-256 public key
      def import(jwk)
        jwk = jwk.transform_keys(&:to_s)
        kty = jwk['kty']
        raise ArgumentError, "the key type #{kty.inspect} is not OKP or EC" unless CURVES.key?(kty)
        raise ArgumentError, "the curve of an #{kty} key is #{CURVES[kty]}" unless jwk['crv'] == CURVES[kty]

        public_key(jwk)
      rescue OpenSSL::PKey::PKeyError, ::JWT::JWKError
        raise ArgumentError, "the key is not a valid #{kty} public key"
      end

      def public_key(jwk)
        return OpenSSL::PKey.new_raw_public_key('ED25519', Base64.urlsafe_decode64(jwk['x'].to_s)) if jwk['kty'] == 'OKP'

        ::JWT::JWK.import(jwk.slice('kty', 'crv', 'x', 'y')).verify_key
      end

      # RFC 7638: the SHA-256 of the required members, in alphabetical order.
      def thumbprint(key) = b64(Digest::SHA256.digest(JSON.generate(public_members(key))))

      def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
    end
  end
end
