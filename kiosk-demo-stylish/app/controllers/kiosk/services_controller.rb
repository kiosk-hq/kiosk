# frozen_string_literal: true

# The salon's service menu.
module Kiosk
  class ServicesController < ApplicationController
    include Kiosk::Handler

    kind :query
    description 'The service menu with prices, cheapest first. Booking a service captures its current price.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'The whole menu.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      service_id: { type: 'integer', description: 'Pass to book_appointment as `service_id`.' },
                      name: { type: 'string', description: 'Service name.' },
                      price_cents: { type: 'integer', description: 'In cents.' },
                      currency: { type: 'string', description: "The price's currency." },
                      price_eur: { type: 'string', description: 'The price for a human, e.g. "€35".' }
                    },
                    required: %w[service_id name price_cents currency price_eur]
                  }
    example_params({})
    example_row({ service_id: 1, name: 'Cut', price_cents: 3500, currency: 'eur', price_eur: '€35' })
    def service_menu
      @menu = Service.order(:price_cents)
    end
  end
end
