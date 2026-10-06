# frozen_string_literal: true

require "kiosk/server/payment_setup"
require "kiosk/server/wire_controller"

module Kiosk
  module Server
    # GET <endpoint>/payment_setup/return — the page a payment provider sends
    # the human's browser back to. `POST <endpoint>/payment_setup` itself is an
    # ordinary verb, served by {VerbController}.
    class PaymentSetupController < WireController
      READY = ["Payment set up", "Your assistant can now pay on your behalf. You can close this tab."].freeze
      UNCONFIRMED = ["Back from payment setup",
                     "Your assistant will check whether the setup is complete. You can close this tab."].freeze

      def show
        PaymentSetup.served!
        title, text = PaymentSetup.returned(request.query_parameters) ? READY : UNCONFIRMED
        render body: page(title, text), content_type: "text/html"
      end

      private

      def page(title, text)
        <<~HTML
          <!DOCTYPE html><html><head><meta charset="utf-8"><title>#{title}</title></head>
          <body style="font-family:system-ui,sans-serif;text-align:center;padding:64px">
          <h1>#{title}</h1><p>#{text}</p>
          </body></html>
        HTML
      end
    end
  end
end
