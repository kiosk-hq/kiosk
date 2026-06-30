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
        # PoC scope: this sets a PROCESS-GLOBAL Stripe key. Multiple adapter instances with different keys would clobber each other; a future fix uses per-request key options.
        ::Stripe.api_key = @api_key
      end

      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @param payment_method [String] assistant-presented PSP payment-method reference
      # @return [Hash] { psp_reference:, settled_amount_cents:, settled_at: }
      def capture(cart_mandate, payment_method:)
        pm = payment_method || @test_payment_method
        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            payment_method: pm,
            confirm:        true,
            capture_method: "automatic",
            metadata:       { cart_mandate_id: cart_mandate.id },
          },
          { idempotency_key: "#{cart_mandate.id}-capture" },
        )

        {
          psp_reference:        intent.id,
          settled_amount_cents: intent.amount_received,
          # NOTE: intent.created is the PaymentIntent creation time — for this synchronous automatic-capture path it is the settlement time to within seconds. A future deferred/manual-capture flow must source the charge timestamp instead.
          settled_at:           Time.at(intent.created).utc,
        }
      end

      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @param payment_method [String] assistant-presented PSP payment-method reference
      # @return [Hash] { stripe_payment_intent_id:, client_secret:, status: }
      def authorize(cart_mandate, payment_method:)
        pm = payment_method || @test_payment_method
        intent = ::Stripe::PaymentIntent.create(
          {
            amount:         cart_mandate.total_amount_cents,
            currency:       cart_mandate.currency,
            payment_method: pm,
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

      # @param settlement [Kiosk::Mandate::Settlement]
      # @param amount_cents [Integer, nil] partial refund; nil = full
      # @return [Hash] { refund_id: }
      def refund(settlement, amount_cents = nil)
        params = { payment_intent: settlement.psp_reference }
        params[:amount] = amount_cents unless amount_cents.nil?

        refund = ::Stripe::Refund.create(params)
        { refund_id: refund.id }
      end
    end
  end
end
