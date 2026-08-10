# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    # Raised when a buyer has no saved payment method at the provider's PSP
    # and must complete the SetupIntent flow before a charge can proceed.
    # The caller (e.g. a Kiosk Action) should surface the setup URL to the
    # assistant so the human can enter their card.
    SetupRequired = Class.new(StandardError)

    # Raised by a PSP adapter when a charge attempt FAILS at the processor
    # (rather than escaping as a raw exception → HTTP 500). A concrete adapter
    # (e.g. kiosk-pay-stripe) translates its PSP-specific errors into this
    # PSP-AGNOSTIC signal, carrying only a human-safe `message` (never raw PSP
    # internals) plus a stable `reason` symbol. The executor maps it to the
    # `payment_failed` wire error (a clean 4xx) — see K-545.
    #
    # `retryable?` splits the two cases that matter for double-charge safety:
    #   true  — the processor reached a DEFINITIVE no-charge decision (card
    #           declined / expired / insufficient funds / authentication
    #           required). Nothing was charged, so a caller may safely release
    #           any in-progress claim and let the human retry with a corrected
    #           method.
    #   false — the charge outcome is UNKNOWN (timeout / connectivity). The
    #           charge MAY have succeeded, so a caller MUST NOT blind-retry
    #           (that would double-charge): it should leave the order claimed
    #           and reconcile / check the settlement first.
    class PaymentFailed < StandardError
      attr_reader :reason

      def initialize(message = "payment failed", reason: :error, retryable: false)
        super(message)
        @reason    = reason
        @retryable = retryable
      end

      def retryable? = @retryable
    end

    # Abstract base for AP2 PSP (Payment Service Provider) adapters.
    # See the Payment (AP2 mandate chain) section of the spec.
    #
    # Subclasses ship as `kiosk-pay-*` gems. Today only `kiosk-pay-stripe`
    # ships; further open adapters (e.g. Paddle) and commercial regional
    # PSPs are planned on customer demand — none exist yet.
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
