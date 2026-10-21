# frozen_string_literal: true

require 'jwt'
require 'securerandom'

module Kiosk
  module Server
    # The checkout an operator answers for an item to pay for: a JWT it signs
    # EdDSA with its signing key. The assistant's checkout mandate names it by
    # hash. EdDSA signatures are deterministic, so a random `jti` makes the hash
    # of each checkout impossible to guess (AP2 v0.2, rainbow table attacks).
    module Checkout
      ALGORITHM = Eddsa::NAME

      module_function

      # @param user_id the account the checkout is for; only that account can pay it
      # @return [String] the compact JWT
      def sign(user_id:, currency:, total_amount_cents:, line_items:)
        signed({ iss: Kiosk.current_issuer, sub: user_id.to_s, iat: Time.now.to_i, jti: SecureRandom.urlsafe_base64(16),
                 merchant: merchant, currency: currency, total_amount_cents: total_amount_cents, line_items: line_items })
      end

      # @return [String] `claims` as a compact JWT, signed EdDSA with the operator's signing key
      def signed(claims)
        key = Kiosk.configuration.signing_key
        ::JWT.encode(claims, key.key, ALGORITHM, { kid: key.kid, typ: 'JWT' })
      end

      # The AP2 Merchant object: the payee the payment mandate names.
      def merchant
        issuer = Kiosk.current_issuer
        { id: issuer, name: Kiosk.configuration.owner[:name] || issuer, website: issuer }
      end

      # @return [Hash] the claims of a checkout this origin signed, with its current or previous key, for this account
      # @raise [Errors::Forbidden]
      def verify(checkout_jwt, identity:)
        claims = decode(checkout_jwt)
        raise Errors::Forbidden.new('checkout is not from this origin', hint: ISSUER_HINT) unless claims['iss'] == Kiosk.current_issuer
        return claims if claims['sub'] == identity.user_id.to_s

        raise Errors::Forbidden.new('checkout is for another account', hint: 'pay only a checkout this operator answered to you')
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new('checkout_jwt signature invalid', hint: ISSUER_HINT)
      end

      # The claims of a checkout that the current or the previous signing key signed.
      def decode(checkout_jwt)
        jwks = Jwks.build(keys: Kiosk.configuration.signing_keys)
        ::JWT.decode(checkout_jwt, nil, true, algorithms: [ALGORITHM]) { |header| Jwks.find(jwks, header['kid']) }.first
      end

      ISSUER_HINT = 'send the checkout_jwt this operator answered, unchanged'
    end
  end
end
