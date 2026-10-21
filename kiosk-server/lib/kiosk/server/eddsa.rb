# frozen_string_literal: true

require 'jwt'
require 'openssl'
require_relative 'jwk'

module Kiosk
  module Server
    # The JOSE algorithm EdDSA (RFC 8037) over the Ed25519 keys of OpenSSL.
    # Loading this file registers `EdDSA` with ruby-jwt, so `JWT.encode` and
    # `JWT.decode` accept the name.
    class Eddsa
      include ::JWT::JWA::SigningAlgorithm

      NAME = 'EdDSA'

      def initialize
        @alg = NAME
      end

      def sign(data:, signing_key:)
        raise_sign_error!("an EdDSA key is an Ed25519 key, got #{signing_key.class}") unless Jwk.ed25519?(signing_key)

        signing_key.sign(nil, data)
      end

      def verify(data:, signature:, verification_key:)
        raise_verify_error!("an EdDSA key is an Ed25519 key, got #{verification_key.class}") unless Jwk.ed25519?(verification_key)

        verification_key.verify(nil, signature, data)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      register_algorithm(new)
    end
  end
end
