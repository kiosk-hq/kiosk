# frozen_string_literal: true

module Kiosk
  module Server
    # The JWKS document (RFC 7517 §5) of this deployment's signing keys.
    module Jwks
      module_function

      def build(keys:)
        { keys: Array(keys).map(&:to_jwk) }
      end
    end
  end
end
