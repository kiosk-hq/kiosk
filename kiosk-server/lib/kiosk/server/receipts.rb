# frozen_string_literal: true

module Kiosk
  module Server
    # The two AP2 v0.2 receipts a settled `pay` answers (§11.3): JWTs this
    # operator signs as it signs a checkout, each naming its mandate by reference.
    module Receipts
      SUCCESS = 'Success'

      module_function

      # @return [Hash] `checkout_receipt` and `payment_receipt`, compact JWTs
      def issue(checkout:, payment:, settlement_id:, psp_reference:, network_confirmation_id:)
        { checkout_receipt: sign(checkout, order_id: order_id(checkout)),
          payment_receipt: sign(payment, payment_id: settlement_id, psp_confirmation_id: psp_reference,
                                         network_confirmation_id: network_confirmation_id) }
      end

      # The id in the checkout's first line item, which names the item paid for (§11.7).
      def order_id(checkout) = checkout.line_items.first.values.first.to_s

      # A network id the PSP did not report is left out.
      def sign(mandate, **claims)
        Checkout.signed({ status: SUCCESS, iss: Kiosk.current_issuer, iat: Time.now.to_i,
                          reference: mandate.reference, **claims }.compact)
      end
    end
  end
end
