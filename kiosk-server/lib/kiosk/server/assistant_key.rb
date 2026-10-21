# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'jwt'
require 'openssl'

module Kiosk
  module Server
    # The public key of an AI assistant: the key it registers, signs its client
    # assertions with and binds its tokens to. This module holds the one list of
    # signing algorithms an assistant can use, and the bounds of its key.
    module AssistantKey
      # Client assertions, DPoP proofs and every metadata list read this list.
      ALGORITHMS = %w[RS256].freeze

      MAX_KEY_BITS = 4096

      # The members of a JWK that only a private key has.
      PRIVATE_MEMBERS = %w[d p q dp dq qi].freeze

      HINT = "send one RSA public key of #{SigningKey::MIN_KEY_BITS} to #{MAX_KEY_BITS} bits as an " \
             'RFC 7517 JWK {"kty":"RSA","n":"…","e":"…"}, with no private member'.freeze

      module_function

      # The key of an RFC 7517 JWK Set that holds exactly one public key.
      # @raise [Errors::BadRequest] naming what is wrong
      def from_jwks(jwks)
        keys = jwks.is_a?(Hash) ? (jwks['keys'] || jwks[:keys]) : nil
        refuse!('jwks must be a JWK Set with exactly one key') unless keys.is_a?(Array) && keys.size == 1

        from_jwk(keys.first)
      end

      # @raise [Errors::BadRequest] naming what is wrong
      def from_jwk(jwk)
        refuse!('the key is not a JWK object') unless jwk.is_a?(Hash)
        jwk = jwk.transform_keys(&:to_s)
        refuse!('the key carries a private member') if jwk.keys.intersect?(PRIVATE_MEMBERS)
        refuse!('the key is not an RSA key') unless jwk['kty'] == 'RSA'

        checked(::JWT::JWK.import(jwk.slice('kty', 'n', 'e')).public_key)
      rescue ::JWT::JWKError, OpenSSL::PKey::PKeyError, ArgumentError
        refuse!('the key is not a valid RSA JWK')
      end

      # @raise [Errors::BadRequest] naming what is wrong
      def from_pem(pem)
        checked(OpenSSL::PKey::RSA.new(pem.to_s))
      rescue OpenSSL::PKey::PKeyError
        refuse!('the key is not a valid RSA public key')
      end

      # The form the agents table stores.
      def to_pem(key) = key.public_to_pem.strip

      # RFC 7517: the public members only.
      def to_jwk(key) = { kty: 'RSA', n: b64(key.n.to_s(2)), e: b64(key.e.to_s(2)) }

      # RFC 7638: the SHA-256 of the required members, in alphabetical order.
      def thumbprint(key)
        jwk = to_jwk(key)
        b64(Digest::SHA256.digest(JSON.generate({ e: jwk[:e], kty: jwk[:kty], n: jwk[:n] })))
      end

      def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

      def checked(key)
        refuse!('the key is a private key') if key.private?
        bits = key.n.num_bits
        refuse!("the key is too small (#{bits} bits)") if bits < SigningKey::MIN_KEY_BITS
        refuse!("the key is too large (#{bits} bits)") if bits > MAX_KEY_BITS
        key
      end

      def refuse!(detail)
        raise Errors::BadRequest.new(detail, hint: HINT)
      end

      private_class_method :b64, :checked, :refuse!
    end
  end
end
