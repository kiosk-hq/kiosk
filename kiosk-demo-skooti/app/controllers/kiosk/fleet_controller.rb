# frozen_string_literal: true

# The fleet: the vehicles a customer can reserve.
class Kiosk::FleetController < ActionController::API
  include Kiosk::Handler

  kind :query
  description "The fleet you can reserve. A `needs_licence` vehicle is rented with `rent_motorcycle`, " \
              "any other with `start_rental`."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    code:                { type: "string", description: "The vehicle's handle; `reserve` takes it as `scooter_code`." },
                    name:                { type: "string", description: "The vehicle's name." },
                    dock:                { type: "string", description: "Where to pick it up." },
                    kind:                { type: "string", enum: %w[scooter motorcycle] },
                    needs_licence:       { type: "boolean", description: "Riding it needs a category-A licence and age 18+." },
                    lat:                 { type: "string", description: "Latitude, as a decimal string." },
                    lng:                 { type: "string", description: "Longitude, as a decimal string." },
                    price_per_min_cents: { type: "integer", description: "Price per minute, in cents." },
                    currency:            { type: "string", description: "The price's currency." },
                  },
                  required: %w[code name dock kind needs_licence lat lng price_per_min_cents currency],
                }
  example_params({})
  example_row({
    code: "SK-001", name: "Jordaan Jet", dock: "Jordaan Dock", kind: "scooter", needs_licence: false,
    lat: "52.3739", lng: "4.8809", price_per_min_cents: 15, currency: "eur",
  })
  def scooters_available
    @scooters = Scooter.available.order(:id)
  end
end
