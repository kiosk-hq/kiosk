# frozen_string_literal: true

require 'json'
require 'base64'

module Kiosk
  module Redteam
    # Reads and edits the payload of a compact JWS. Nothing here verifies a signature.
    module TokenClaims
      module_function

      # The payload claims as a Hash, or nil when the token does not decode to one.
      def claims(token)
        payload_b64 = token.to_s.split('.')[1]
        return nil if payload_b64.nil?

        parsed = decode(payload_b64)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      # Changes one payload claim and keeps the original signature.
      def tamper(token)
        header, payload_b64, sig = token.split('.', 3)
        return token if payload_b64.nil?

        new_payload = Base64.urlsafe_encode64(JSON.generate(flip(decode(payload_b64))), padding: false)
        [header, new_payload, sig].join('.')
      end

      def decode(payload_b64)
        padded = payload_b64 + ('=' * ((4 - (payload_b64.length % 4)) % 4))
        JSON.parse(Base64.urlsafe_decode64(padded))
      end

      def flip(claims)
        if claims.key?('role')
          claims['role'] = claims['role'] == 'admin' ? 'superadmin' : 'admin'
        elsif claims.key?('sub')
          claims['sub'] = "#{claims['sub']}-tampered"
        elsif claims.key?('exp')
          claims['exp'] = (claims['exp'].to_i + 999_999)
        else
          claims['__tamper__'] = true
        end
        claims
      end
    end
  end
end
