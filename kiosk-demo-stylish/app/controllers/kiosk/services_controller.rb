# frozen_string_literal: true

# The salon's service menu.
class Kiosk::ServicesController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "The service menu with prices, cheapest first. Booking a service captures its current price."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The whole menu.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    service_id:  { type: "integer", description: "Pass to book_appointment as `service_id`." },
                    name:        { type: "string", description: "Service name." },
                    price_cents: { type: "integer", description: "EUR cents." },
                    currency:    { type: "string", description: "EUR." },
                    price_eur:   { type: "string", description: "The price for a human, e.g. \"€35\"." },
                  },
                  required: %w[service_id name price_cents currency price_eur],
                }
  example_params({})
  example_row({ service_id: 1, name: "Cut", price_cents: 3500, currency: "EUR", price_eur: "€35" })
  def service_menu
    @menu = Service.order(:price_cents)
  end

  kind :query
  description "The services open for booking, cheapest first. This salon never fills up, so that is every service."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "Every service on the menu.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    service_id:  { type: "integer", description: "Pass to book_appointment as `service_id`." },
                    service:     { type: "string", description: "Service name." },
                    price_cents: { type: "integer", description: "EUR cents." },
                    open:        { const: true, description: "Always true." },
                    currency:    { type: "string", description: "EUR." },
                    price_eur:   { type: "string", description: "The price for a human, e.g. \"€90\"." },
                  },
                  required: %w[service_id service price_cents open currency price_eur],
                }
  example_params({})
  example_row({ service_id: 3, service: "Colour", open: true, currency: "EUR", price_cents: 9000, price_eur: "€90" })
  def availability
    @menu = Service.order(:price_cents)
  end
end
