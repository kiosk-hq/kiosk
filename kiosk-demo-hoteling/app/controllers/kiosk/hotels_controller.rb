# frozen_string_literal: true

# The hotel catalogue.

module Kiosk
  class HotelsController < ActionController::API
    include Kiosk::Handler

    kind :query
    description 'Every hotel here, by name. `search_hotels` narrows them down.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      property_id: { type: 'integer', description: 'Pass to availability and hotel_detail.' },
                      name: { type: 'string', description: 'Hotel name.' },
                      city: { type: 'string' }
                    },
                    required: %w[property_id name city]
                  }
    def properties
      @properties = Property.order(:name)
    end

    kind :query
    description 'One hotel in full, as a one-row array. Given a stay, `room_types` lists only the rooms free ' \
                'for those nights; without one, every room type the hotel has.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   property_id: { type: 'integer', description: 'From a search_hotels or properties row.' },
                   check_in: { type: 'string', format: 'date',
                               description: "First night, on the hotel's own clock (`timezone`). Pass with check_out." },
                   check_out: { type: 'string', format: 'date', description: 'Checkout day. Pass with check_in.' }
                 },
                 required: ['property_id']
    output_schema type: 'array',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      property_id: { type: 'integer' },
                      name: { type: 'string' },
                      neighbourhood: { type: %w[string null], description: 'Istanbul area.' },
                      stars: { type: 'integer' },
                      address: { type: %w[string null] },
                      amenities: { type: 'array', items: { type: 'string' } },
                      currency: { type: 'string', description: 'Sign the cart in this currency.' },
                      check_in: { type: %w[string null],
                                  description: 'The first night `room_types` is free for; null when no dates were given.' },
                      check_out: { type: %w[string null], description: 'The checkout day; null when no dates were given.' },
                      timezone: { type: 'string', description: "The IANA zone the hotel's calendar runs on." },
                      room_types: {
                        type: 'array',
                        description: 'Cheapest first.',
                        items: {
                          type: 'object', additionalProperties: false,
                          properties: {
                            room_type_id: { type: 'integer', description: 'Pass to reserve_room.' },
                            name: { type: 'string' },
                            nightly_price_cents: { type: 'integer', description: 'Price per night, in cents.' }
                          },
                          required: %w[room_type_id name nightly_price_cents]
                        }
                      }
                    },
                    required: %w[property_id name neighbourhood stars address amenities currency
                                 check_in check_out timezone room_types]
                  }
    example_params({ property_id: 4,
                     check_in: -> { Time.find_zone!('Europe/Istanbul').tomorrow.iso8601 },
                     check_out: -> { (Time.find_zone!('Europe/Istanbul').tomorrow + 3).iso8601 } })
    example_row({
                  property_id: 4, name: 'Bosphorus Palace', neighbourhood: 'Beşiktaş', stars: 5,
                  address: 'Çırağan Cd. 88, Beşiktaş, Istanbul',
                  amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
                  currency: 'eur',
                  check_in: -> { Time.find_zone!('Europe/Istanbul').tomorrow.iso8601 },
                  check_out: -> { (Time.find_zone!('Europe/Istanbul').tomorrow + 3).iso8601 },
                  timezone: 'Europe/Istanbul',
                  room_types: [
                    { room_type_id: 7, name: 'Classic', nightly_price_cents: 15_000 },
                    { room_type_id: 8, name: 'Bosphorus', nightly_price_cents: 25_000 }
                  ]
                })
    def hotel_detail
      @property = Property.find(params.expect(:property_id))
      @search   = RoomSearch.new(property: @property, check_in: params[:check_in], check_out: params[:check_out])
      @search.validate!
    end
  end
end
