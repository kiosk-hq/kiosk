# frozen_string_literal: true

require "kiosk/server/payment_setup"
require "kiosk/server/wire_controller"

module Kiosk
  module Server
    # GET <endpoint>/payment_setup/return — the page a payment provider sends
    # the human's browser back to. `POST <endpoint>/payment_setup` itself is an
    # ordinary verb, served by {VerbController}.
    class PaymentSetupController < WireController
      PAGE = <<~HTML
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Payment set up</title></head>
        <body style="font-family:system-ui,sans-serif;text-align:center;padding:64px">
        <h1>Payment set up</h1><p>Your assistant can now pay on your behalf. You can close this tab.</p>
        </body></html>
      HTML

      def show
        PaymentSetup.served!
        PaymentSetup.returned(request.query_parameters)
        render body: PAGE, content_type: "text/html"
      end
    end
  end
end
