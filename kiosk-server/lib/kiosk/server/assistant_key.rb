# frozen_string_literal: true

require 'openssl'

module Kiosk
  module Server
    # The public key of an AI assistant: the key it registers, signs its client
    # assertions, DPoP proofs and mandates with, and binds its tokens to. An
    # Ed25519 key signs EdDSA. A P-256 key signs ES256 where the operator
    # accepts ES256 (`c.assistant_algorithms`).
    module AssistantKey
      # The members of a JWK that only a private key has.
      PRIVATE_MEMBERS = %w[d].freeze

      module_function

      # The algorithms this operator accepts, EdDSA first. Client assertions,
      # DPoP proofs, mandates and every metadata list read this list.
      def algorithms = Kiosk.configuration.assistant_algorithms

      def hint
        keys = ['an Ed25519 key as an RFC 8037 JWK {"kty":"OKP","crv":"Ed25519","x":"…"}']
        keys << 'a P-256 key as an RFC 7518 JWK {"kty":"EC","crv":"P-256","x":"…","y":"…"}' if algorithms.include?('ES256')
        "send one public key: #{keys.join(', or ')}, with no private member"
      end

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
        refuse!("the key is not an #{curves} key") unless key_types.include?(jwk['kty'])

        accepted(Jwk.import(jwk))
      rescue ArgumentError => e
        refuse!(e.message)
      end

      # The key of a row of the agents table.
      # @raise [Errors::BadRequest] when this operator does not accept the key
      def from_pem(pem)
        accepted(OpenSSL::PKey.read(pem.to_s))
      rescue OpenSSL::PKey::PKeyError
        refuse!('the key is not a valid public key')
      end

      # The form the agents table stores.
      def to_pem(key) = key.public_to_pem.strip

      # RFC 7517: the public members only.
      def to_jwk(key) = Jwk.public_members(key)

      # RFC 7638.
      def thumbprint(key) = Jwk.thumbprint(key)

      # The one algorithm `key` signs with.
      def algorithm(key) = Jwk.algorithm(key)

      # `OKP`, and `EC` where ES256 is accepted.
      def key_types = algorithms.map { Jwk::ALGORITHMS.key(it) }

      def curves = key_types.map { Jwk::CURVES[it] }.join(' or ')

      def accepted(key)
        refuse!('the key is a private key') if Jwk.private?(key)
        refuse!("the key is not an #{curves} key") unless algorithms.include?(algorithm(key))
        key
      end

      def refuse!(detail)
        raise Errors::BadRequest.new(detail, hint: hint)
      end

      private_class_method :key_types, :curves, :accepted, :refuse!
    end
  end
end
