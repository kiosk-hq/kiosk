# frozen_string_literal: true

module Kiosk
  module Server
    # Verifies the two closed AP2 v0.2 mandates of a `pay`. Each is an SD-JWT
    # signed with the authenticated agent's key. The checkout mandate binds a
    # checkout this origin signed for this account; the payment mandate pays
    # exactly that checkout, to this origin.
    module MandateVerifier
      # §11.1: an ISO 4217 alpha-3 code, matched after {canonical_currency}.
      CURRENCY_CODE = /\A[a-z]{3}\z/

      CHECKOUT_VCT = 'mandate.checkout.1'
      PAYMENT_VCT  = 'mandate.payment.1'
      TYP          = 'dc+sd-jwt'
      ALGORITHM    = 'RS256'

      # Longer than this counts as non-expiring, which the spec refuses.
      MAX_MANDATE_LIFETIME_SECONDS = 24 * 60 * 60

      module_function

      def verify_checkout(sd_jwt:, identity:)
        content = Token.content(sd_jwt, identity, CHECKOUT_VCT)
        checkout_jwt, checkout_hash = Binding.checkout_jwt!(content)
        checkout = Checkout.verify(checkout_jwt, identity: identity)
        Kiosk::Mandate::CheckoutMandate.new(
          **Token.common(sd_jwt, content, identity),
          checkout_hash: checkout_hash,
          line_items: checkout['line_items'],
          total_amount_cents: checkout['total_amount_cents'],
          currency: canonical_currency(checkout['currency'])
        )
      end

      def verify_payment(sd_jwt:, identity:, checkout:)
        content = Token.content(sd_jwt, identity, PAYMENT_VCT)
        Binding.payment_to_checkout!(content, checkout)
        instrument = Binding.instrument!(content['payment_instrument'])

        Kiosk::Mandate::PaymentMandate.new(
          **Token.common(sd_jwt, content, identity), transaction_id: content['transaction_id'],
                                                     payment_instrument: instrument, amount_cents: checkout.total_amount_cents, currency: checkout.currency
        )
      end

      CHECKOUT_HINT = 'a checkout mandate carries the checkout_jwt the operator answered, unchanged, and ' \
                      'checkout_hash: the base64url SHA-256 of that string'

      # Public: an operator reading `settlements.currency` needs the same lower-casing.
      def canonical_currency(value)
        value.to_s.downcase
      end

      # How the payment mandate must agree with the checkout it pays.
      module Binding
        module_function

        # @return [Array(String, String)] the checkout_jwt and its hash
        def checkout_jwt!(content)
          checkout_jwt = content['checkout_jwt']
          raise Errors::Forbidden.new('checkout mandate has no checkout_jwt', hint: CHECKOUT_HINT) unless checkout_jwt.is_a?(String)

          checkout_hash = SdJwt.digest(checkout_jwt)
          return [checkout_jwt, checkout_hash] if content['checkout_hash'] == checkout_hash

          raise Errors::Forbidden.new('checkout_hash is not the hash of checkout_jwt', hint: CHECKOUT_HINT)
        end

        def payment_to_checkout!(content, checkout)
          raise Errors::Forbidden.new('payment not bound to the checkout', hint: 'transaction_id is the checkout_hash of the checkout mandate') unless content['transaction_id'] == checkout.checkout_hash

          payee!(content['payee'])
          amount!(content['payment_amount'], checkout)
        end

        def payee!(payee)
          issuer = Kiosk.current_issuer
          return if payee.is_a?(Hash) && payee['id'] == issuer

          raise Errors::Forbidden.new('payment payee is not this origin', hint: "payee is the checkout's merchant, whose id is #{issuer.inspect}")
        end

        # The signed amount must be the checkout's, in its currency, compared as a code.
        def amount!(amount, checkout)
          return if amount.is_a?(Hash) && amount['amount'] == checkout.total_amount_cents &&
                    amount['currency'].is_a?(String) && MandateVerifier.canonical_currency(amount['currency']) == checkout.currency

          raise Errors::Forbidden.new('payment amount/currency does not match the checkout',
                                      hint: "payment_amount is {amount: #{checkout.total_amount_cents}, currency: #{checkout.currency.inspect}}")
        end

        # @return [String] the instrument id: a PSP payment-method id, or `on_file`
        def instrument!(instrument)
          return instrument['id'] if instrument.is_a?(Hash) && [instrument['id'], instrument['type']].all? { it.is_a?(String) && !it.empty? }

          raise Errors::Forbidden.new('payment mandate has no payment_instrument',
                                      hint: 'payment_instrument is {id, type}; {"id": "on_file", "type": "card"} pays with the saved card')
        end
      end

      # The SD-JWT: its signature, its type and its lifetime.
      module Token
        module_function

        # The attributes both mandates carry.
        def common(sd_jwt, content, identity)
          { reference: SdJwt.digest(sd_jwt), user_id: identity.user_id, agent_id: identity.agent_id,
            issuer: Kiosk.current_issuer, expires_at: Time.at(content['exp']).utc, sd_jwt: sd_jwt }
        end

        # The one mandate in `delegate_payload`, with every disclosure in place.
        def content(sd_jwt, identity, vct)
          payload = decode(sd_jwt, identity)
          content = payload['delegate_payload']
          content = content.first if content.is_a?(Array) && content.one?
          raise Errors::Forbidden.new('mandate carries no mandate', hint: SHAPE_HINT) unless content.is_a?(Hash)
          raise Errors::Forbidden.new("mandate vct is not #{vct}", hint: VCT_HINT) unless content['vct'] == vct

          check_lifetime!(content)
          content
        end

        SHAPE_HINT = 'the signed payload is {"_sd_alg": "sha-256", "delegate_payload": [{"...": <digest>}]}, ' \
                     'and the one disclosure is the mandate'
        VCT_HINT   = "send closed mandates: #{CHECKOUT_VCT} and #{PAYMENT_VCT}. This operator takes no open mandate".freeze

        def decode(sd_jwt, identity)
          payload, header = SdJwt.verify(sd_jwt, key: payment_key(identity), algorithm: ALGORITHM)
          return payload if header['typ'] == TYP

          raise Errors::Forbidden.new("mandate typ is not #{TYP}", hint: "the JWT header is {\"alg\": \"#{ALGORITHM}\", \"typ\": \"#{TYP}\"}")
        rescue SdJwt::Invalid => e
          raise Errors::Forbidden.new('mandate is not a valid SD-JWT', hint: e.message)
        rescue ::JWT::DecodeError
          raise Errors::Forbidden.new('mandate signature invalid', hint: "a mandate is an SD-JWT signed #{ALGORITHM} with the agent's payment key")
        end

        def payment_key(identity)
          AgentIdentityProviders::DefaultAgentIdp.new.agent_payment_key(identity.agent_id)
        rescue Kiosk::AgentIdentityProviders::InvalidToken
          # The agent was revoked between authentication and now.
          raise Errors::Forbidden.new('mandate agent has no registered payment key', hint: 'the authenticated agent is revoked or unknown')
        end

        def check_lifetime!(content)
          require_numeric_timestamp!(content, 'iat')
          require_numeric_timestamp!(content, 'exp')
          raise Errors::Forbidden, 'mandate expired' if content['exp'] <= Time.now.to_i

          enforce_max_lifetime!(content)
        end

        # Before `Time.at`, which raises on a String.
        def require_numeric_timestamp!(content, field)
          return if content[field].is_a?(Integer)

          raise Errors::BadRequest.new(
            "mandate #{field} must be an integer Unix timestamp",
            hint: "#{field} was #{content[field].class} — send #{field} as a NumericDate integer"
          )
        end

        # exp − now, not exp − iat, so a future-dated iat cannot stretch it.
        def enforce_max_lifetime!(content)
          return if content['exp'] - Time.now.to_i <= MAX_MANDATE_LIFETIME_SECONDS

          raise Errors::BadRequest.new(
            "mandate lifetime exceeds the maximum of #{MAX_MANDATE_LIFETIME_SECONDS}s",
            hint: "exp must be at most #{MAX_MANDATE_LIFETIME_SECONDS}s in the future; " \
                  'a non-expiring mandate is rejected'
          )
        end
      end
    end
  end
end
