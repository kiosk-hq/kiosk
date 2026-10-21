# frozen_string_literal: true

require 'jwt'

module Kiosk
  module Server
    # The checkout an operator answers for an item to pay for: a JWT it signs
    # with its signing key. AP2 requires a randomized signature here, so it is
    # PS256 and not RS256. The assistant's checkout mandate names it by hash.
    module Checkout
      ALGORITHM = 'PS256'

      module_function

      # @param user_id the account the checkout is for; only that account can pay it
      # @return [String] the compact JWT
      def sign(user_id:, currency:, total_amount_cents:, line_items:)
        key = Kiosk.configuration.signing_key
        claims = { iss: Kiosk.current_issuer, sub: user_id.to_s, iat: Time.now.to_i, merchant: merchant,
                   currency: currency, total_amount_cents: total_amount_cents, line_items: line_items }
        ::JWT.encode(claims, key.rsa, ALGORITHM, { kid: key.kid, typ: 'JWT' })
      end

      # The AP2 Merchant object: the payee the payment mandate names.
      def merchant
        issuer = Kiosk.current_issuer
        { id: issuer, name: Kiosk.configuration.owner[:name] || issuer, website: issuer }
      end

      # @return [Hash] the claims of a checkout this origin signed for this account
      # @raise [Errors::Forbidden]
      def verify(checkout_jwt, identity:)
        claims, = ::JWT.decode(checkout_jwt, Kiosk.configuration.signing_key.public_key, true, algorithms: [ALGORITHM])
        raise Errors::Forbidden.new('checkout is not from this origin', hint: ISSUER_HINT) unless claims['iss'] == Kiosk.current_issuer
        return claims if claims['sub'] == identity.user_id.to_s

        raise Errors::Forbidden.new('checkout is for another account', hint: 'pay only a checkout this operator answered to you')
      rescue ::JWT::DecodeError
        raise Errors::Forbidden.new('checkout_jwt signature invalid', hint: ISSUER_HINT)
      end

      ISSUER_HINT = 'send the checkout_jwt this operator answered, unchanged'
    end
  end
end
