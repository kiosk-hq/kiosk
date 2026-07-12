# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    # Raised when a buyer has no saved payment method at the provider's PSP
    # and must complete the SetupIntent flow before a charge can proceed.
    # The caller (e.g. a Kiosk Action) should surface the setup URL to the
    # assistant so the human can enter their card.
    SetupRequired = Class.new(StandardError)

    # Abstract base for AP2 PSP (Payment Service Provider) adapters.
    # See the Payment (AP2 mandate chain) section of the spec.
    #
    # Subclasses ship as `kiosk-pay-*` gems. Stripe and Paddle are open
    # (drive global adoption); regional PSPs — Tinkoff, YooKassa,
    # CloudPayments, SberPay, ESIA-pay, … — are commercial and built on
    # customer demand rather than upfront.
    class Base
      # Returns true when the principal MUST complete a payment setup flow
      # (e.g. Stripe SetupIntent — card-on-file) before a charge can proceed.
      # The executor calls this BEFORE persisting the mandate trail so it can
      # return a clean 402 without burning the mandate ids.
      #
      # Default: false — StubPsp and adapters without a SetupIntent model
      # inherit this and are never gated.  Stripe overrides when a
      # customer_resolver is configured.
      #
      # @param user_id [String] principal identifier
      # @return [Boolean]
      def setup_required?(user_id:) # rubocop:disable Lint/UnusedMethodArgument
        false
      end

      # Capture a cart mandate into a settlement.
      # The PSP charges the `payment_method` presented by the assistant.
      # Returns the settlement details the caller persists as the PSP receipt.
      #
      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @param payment_method [String] PSP payment-method reference from the
      #   assistant's signed {Kiosk::Mandate::PaymentMandate}
      # @return [Hash] settlement details: `psp_reference`,
      #   `settled_amount_cents`, `settled_at`
      def capture(_cart_mandate, payment_method:)
        raise NotImplementedError, "#{self.class}#capture must be implemented by the adapter"
      end
    end
  end
end
