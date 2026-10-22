# frozen_string_literal: true

module Kiosk
  module Server
    # GET <endpoint>/payment_setup/return — the page a payment provider sends
    # the human's browser back to. `POST <endpoint>/payment_setup` itself is an
    # ordinary verb, served by {VerbController}.
    class PaymentSetupController < WireController
      READY = ['Payment set up', 'Your assistant can now pay on your behalf. You can close this tab.'].freeze
      UNCONFIRMED = ['Back from payment setup',
                     'Your assistant will check whether the setup is complete. You can close this tab.'].freeze

      def show
        PaymentSetup.served!
        title, text = PaymentSetup.returned(request.query_parameters) ? READY : UNCONFIRMED
        render body: page(title, text), content_type: 'text/html'
      end

      private

      # No script and no inline style: a host Content-Security-Policy of `default-src 'self'` holds.
      def page(title, text)
        <<~HTML
          <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>#{title}</title></head>
          <body><main><h1>#{title}</h1><p>#{text}</p></main></body></html>
        HTML
      end
    end
  end
end
