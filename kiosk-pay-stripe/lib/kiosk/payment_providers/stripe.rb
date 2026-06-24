# frozen_string_literal: true

require "kiosk"
require "kiosk/payment_providers/stripe/version"

module Kiosk
  module PaymentProviders
    # Stripe PSP adapter (test mode for the PoC). See design spec §5.5.
    # NOTE: always reference the SDK as `::Stripe` — bare `Stripe` resolves
    # to this class.
    class Stripe < Base
      VERSION = StripeVersion::VERSION

      # @param api_key [String] Stripe secret key (sk_test_… for the PoC)
      # @param test_payment_method [String] Stripe test PaymentMethod id
      def initialize(api_key: nil, test_payment_method: "pm_card_visa")
        super()
        @api_key             = api_key || ENV.fetch("STRIPE_SECRET_KEY", nil)
        @test_payment_method = test_payment_method
        require "stripe"
        ::Stripe.api_key = @api_key
      end

      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @return [Hash] { psp_reference:, settled_amount_cents:, settled_at: }
      def capture(cart_mandate)
        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            payment_method: @test_payment_method,
            confirm:        true,
            capture_method: "automatic",
            metadata:       { cart_mandate_id: cart_mandate.id },
          },
          { idempotency_key: "#{cart_mandate.id}-capture" },
        )

        {
          psp_reference:        intent.id,
          settled_amount_cents: intent.amount_received,
          settled_at:           Time.at(intent.created).utc,
        }
      end

      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @return [Hash] { stripe_payment_intent_id:, client_secret:, status: }
      def authorize(cart_mandate)
        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            payment_method: @test_payment_method,
            confirm:        true,
            capture_method: "manual",
            metadata:       { cart_mandate_id: cart_mandate.id },
          },
          { idempotency_key: "#{cart_mandate.id}-auth" },
        )

        {
          stripe_payment_intent_id: intent.id,
          client_secret:            intent.client_secret,
          status:                   intent.status,
        }
      end
    end
  end
end
