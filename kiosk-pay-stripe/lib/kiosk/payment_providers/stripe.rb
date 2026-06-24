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
    end
  end
end
