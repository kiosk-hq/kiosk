# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # Creates the off_session PaymentIntent and maps its outcome to PaymentFailed.
      module Charges
        private

        def charge(cart_mandate, customer_id, payment_method)
          @stripe.payment_intents.create(
            intent_params(cart_mandate, customer_id, payment_method),
            { idempotency_key: "#{cart_mandate.id}-capture" }
          )
        rescue ::Stripe::CardError => e
          # A definitive decline: nothing was charged, so a retry is safe.
          raise PaymentFailed.new(card_decline_message(e), reason: :card_declined, retryable: true)
        rescue ::Stripe::StripeError
          # The outcome is unknown: a blind retry could double-charge.
          raise unknown_outcome('could not confirm the charge')
        end

        def intent_params(cart_mandate, customer_id, payment_method)
          {
            amount: cart_mandate.total_amount_cents,
            currency: cart_mandate.currency,
            customer: customer_id,
            payment_method: payment_method,
            payment_method_types: ['card'],
            off_session: true,
            confirm: true,
            metadata: { cart_mandate_id: cart_mandate.id }
          }
        end

        def ensure_paid!(intent)
          return if intent.status == PAID

          raise PaymentFailed.new('the payment method was declined', reason: :card_declined, retryable: true) if
            NOT_CHARGED.include?(intent.status)

          raise unknown_outcome('has not completed the charge')
        end

        def unknown_outcome(what)
          PaymentFailed.new("the payment processor #{what}; its status is unknown",
                            reason: :processor_unavailable, retryable: false)
        end

        # Keyed on Stripe's stable error code: Stripe's own message can carry request ids.
        def card_decline_message(error)
          case error.respond_to?(:code) ? error.code : nil
          when 'expired_card'            then 'the payment method has expired'
          when 'insufficient_funds'      then 'the payment method has insufficient funds'
          when 'authentication_required' then 'the payment method needs authentication an off-session charge cannot complete'
          else 'the payment method was declined'
          end
        end
      end
    end
  end
end
