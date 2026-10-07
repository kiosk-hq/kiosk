# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    # The principal has nothing to charge yet; their human must finish
    # {Base#setup_url} first.
    SetupRequired = Class.new(StandardError)

    # A charge failed at the processor; the executor answers `payment_failed`.
    # `message` is human-safe and `reason` a stable symbol. `retryable?` is
    # true only when nothing was charged; false means the outcome is unknown,
    # so the caller reconciles rather than retrying.
    class PaymentFailed < StandardError
      attr_reader :reason

      def initialize(message = "payment failed", reason: :error, retryable: false)
        super(message)
        @reason    = reason
        @retryable = retryable
      end

      def retryable? = @retryable
    end

    # Port for a payment processor adapter (`kiosk-pay-*` gems):
    # `setup_required?`, `setup_url` and `capture`. An adapter that can name
    # whose setup a returning browser reports also defines
    # `setup_return_user_id(params)`, and kiosk-server then serves the
    # `payment_setup` event topic.
    class Base
      # True when the principal's human must finish {#setup_url} before a
      # charge. Asked before the mandate trail is persisted.
      #
      # @param user_id [String] principal identifier
      # @return [Boolean]
      def setup_required?(user_id:) # rubocop:disable Lint/UnusedMethodArgument
        false
      end

      # The page the human opens to make payment possible, e.g. a hosted
      # card-entry form. Asked only when {#setup_required?} answers true. The
      # PSP sends the human's browser to `return_url` when they are done.
      #
      # @param user_id [String] principal identifier
      # @param return_url [String] absolute url of the engine's return page
      # @return [String]
      def setup_url(user_id:, return_url:) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#setup_url must be implemented by an adapter " \
                                   "whose setup_required? can answer true"
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
