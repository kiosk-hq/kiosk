# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    # The principal has nothing to charge yet; their human must finish {Base#setup_url} first.
    class SetupRequired < StandardError
    end

    # A charge failed at the processor. `retryable?` is true only when nothing
    # was charged; false means the outcome is unknown, so reconcile, do not retry.
    class PaymentFailed < StandardError
      def initialize(message = 'payment failed', retryable: false)
        super(message)
        @retryable = retryable
      end

      def retryable? = @retryable
    end

    # Port for a payment processor adapter (`kiosk-pay-*`). An adapter that also
    # defines `setup_return_user_id(params)` gets the `payment_setup` event topic.
    class Base
      # Asked before the mandate trail is persisted.
      def setup_required?(user_id:) # rubocop:disable Lint/UnusedMethodArgument
        false
      end

      # The page the human opens to make payment possible; the PSP returns the browser to `return_url`.
      def setup_url(user_id:, return_url:)
        raise NotImplementedError, "#{self.class}#setup_url must be implemented by an adapter " \
                                   'whose setup_required? can answer true'
      end

      # @return [Hash] `psp_reference`, `settled_amount_cents`, `settled_at`
      def capture(_cart_mandate, payment_method:)
        raise NotImplementedError, "#{self.class}#capture must be implemented by the adapter"
      end

      # Returns `amount_cents` of the charge `psp_reference` to the card.
      # @return [Hash] `psp_reference` (of the refund), `refunded_psp_reference`, `refunded_amount_cents`, `refunded_at`
      def refund(psp_reference:, amount_cents:)
        raise NotImplementedError, "#{self.class}#refund must be implemented by an adapter whose operator refunds"
      end

      # A repeat of a chain whose capture did not complete. The adapter keys its
      # capture by the cart mandate id, so a second capture cannot charge twice.
      def resume(cart_mandate, payment_method:) = capture(cart_mandate, payment_method:)
    end
  end
end
