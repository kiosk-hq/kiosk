# frozen_string_literal: true

# The fleet: the vehicles a customer can reserve.
module Kiosk
  class FleetController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'The vehicles you can reserve now: one another rider holds is left out. A vehicle that names a ' \
                '`licence_category` is rented with `rent_motorcycle`, any other with `start_rental`.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      code: { type: 'string', description: "The vehicle's handle; `reserve` takes it as `scooter_code`." },
                      name: { type: 'string', description: "The vehicle's name." },
                      dock: { type: 'string', description: 'Where to pick it up.' },
                      kind: { type: 'string', enum: %w[scooter motorcycle] },
                      licence_category: { type: %w[string null], enum: ['A1', 'A', nil],
                                          description: 'The driving-licence category riding it needs, or null for ' \
                                                       'none. Riding it needs your human verified as `age_over_18` ' \
                                                       'and with the licence attribute of that category: ' \
                                                       '`licence_a1` for A1, `licence_a` for A.' },
                      lat: { type: 'string', description: 'Latitude, as a decimal string.' },
                      lng: { type: 'string', description: 'Longitude, as a decimal string.' },
                      price_per_min_cents: { type: 'integer', description: 'Price per minute, in cents.' },
                      currency: { type: 'string', description: "The price's currency." }
                    },
                    required: %w[code name dock kind licence_category lat lng price_per_min_cents currency]
                  }
    example_params({})
    example_row({
                  code: 'SK-001', name: 'Jordaan Jet', dock: 'Jordaan Dock', kind: 'scooter', licence_category: nil,
                  lat: '52.3739', lng: '4.8809', price_per_min_cents: 15, currency: 'eur'
                })
    def scooters_available
      @scooters = Scooter.available.order(:id)
    end
  end
end
