# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/payment_setup"
require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # POST <endpoint>/payment_setup, and GET <endpoint>/payment_setup/return —
    # the page a payment provider sends the human's browser back to.
    class PaymentSetupController < VerbController
      PAGE = <<~HTML
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Payment set up</title></head>
        <body style="font-family:system-ui,sans-serif;text-align:center;padding:64px">
        <h1>Payment set up</h1><p>Your assistant can now pay on your behalf. You can close this tab.</p>
        </body></html>
      HTML

      before_action :payment_module_served!

      def show
        PaymentSetup.returned(request.query_parameters)
        render body: PAGE, content_type: "text/html"
      end

      private

      def payment_module_served!
        return if Kiosk.configuration.payment_provider

        raise Errors::ModuleNotServed.new(
          "this operator does not serve the payment module",
          hint: "`pay` is absent from this origin's capabilities; hand the transaction to your human",
        )
      end
    end
  end
end
