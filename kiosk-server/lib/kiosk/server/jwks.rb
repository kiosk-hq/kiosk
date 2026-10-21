# frozen_string_literal: true

module Kiosk
  module Server
    # The JWKS document (RFC 7517 §5) of this deployment's signing keys.
    module Jwks
      module_function

      def build(keys:)
        { keys: Array(keys).map(&:to_jwk) }
      end

      # The public key of the JWK in `jwks` whose `kid` is `kid`, or nil.
      def find(jwks, kid)
        jwk = Array(jwks[:keys] || jwks['keys']).find { |k| (k[:kid] || k['kid']) == kid }
        jwk && Jwk.import(jwk)
      end
    end
  end
end
