# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    # Abstract base for AP2 PSP (Payment Service Provider) adapters.
    # See design spec §5.5 «Agent payments (AP2)».
    #
    # Subclasses ship as `kiosk-pay-*` gems. Stripe and Paddle are open
    # (drive global adoption); regional PSPs — Tinkoff, YooKassa,
    # CloudPayments, SberPay, ESIA-pay, … — are commercial and built on
    # customer demand rather than upfront (see spec §15.3).
    class Base
      # Authorise a cart mandate: PSP-side intent or hold creation.
      #
      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @return [Hash] PSP-specific payload to embed in the response
      def authorize(_cart_mandate)
        raise NotImplementedError, "#{self.class}#authorize must be implemented by the adapter"
      end

      # Capture an authorised cart mandate into a settlement.
      # Returns the data the caller needs to construct a
      # {Kiosk::Mandate::PaymentMandate}.
      #
      # @param cart_mandate [Kiosk::Mandate::CartMandate]
      # @return [Hash] settlement details: `psp_reference`,
      #   `settled_amount_cents`, `settled_at`
      def capture(_cart_mandate)
        raise NotImplementedError, "#{self.class}#capture must be implemented by the adapter"
      end

      # Refund a previously settled payment mandate.
      #
      # @param payment_mandate [Kiosk::Mandate::PaymentMandate]
      # @param amount_cents [Integer, nil] partial refund amount; nil = full
      # @return [Hash] PSP refund reference
      def refund(_payment_mandate, _amount_cents = nil)
        raise NotImplementedError, "#{self.class}#refund must be implemented by the adapter"
      end
    end
  end
end
