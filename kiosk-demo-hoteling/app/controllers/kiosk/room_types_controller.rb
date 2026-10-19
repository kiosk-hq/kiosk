# frozen_string_literal: true

# A hotel's room types free for a stay.

module Kiosk
  class RoomTypesController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'Room types free at one hotel for one stay, cheapest first; empty means sold out for those ' \
                'nights. Rates are per night; `reserve_room` quotes the whole stay.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   property_id: { type: 'integer', description: 'From a properties or search_hotels row.' },
                   check_in: { type: 'string', format: 'date',
                               description: "First night, on the hotel's own clock (`timezone` in hotel_detail). " \
                                            'Tonight is bookable.' },
                   check_out: { type: 'string', format: 'date',
                                description: "Checkout day, on the hotel's own clock; the next guest can check in " \
                                             'that day.' }
                 },
                 required: %w[property_id check_in check_out]
    output_schema type: 'array',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      room_type_id: { type: 'integer', description: 'Pass to reserve_room.' },
                      name: { type: 'string' },
                      nightly_price_cents: { type: 'integer', description: 'Price per night, in cents.' },
                      currency: { type: 'string', description: 'Sign the cart in this currency.' }
                    },
                    required: %w[room_type_id name nightly_price_cents currency]
                  }
    def availability
      @search = RoomSearch.new(property: Property.find(params.expect(:property_id)),
                               check_in: params[:check_in], check_out: params[:check_out])
      @search.validate!
    end
  end
end
