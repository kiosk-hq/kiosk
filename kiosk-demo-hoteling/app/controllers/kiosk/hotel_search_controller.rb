# frozen_string_literal: true

# The hotel search.

module Kiosk
  class HotelSearchController < ActionController::API
    include Kiosk::Handler

    SEARCH_PAGE = 20
    SEARCH_MAX  = 50

    # Each filter the caller passed narrows the hotels, in this order.
    FILTERS = {
      neighbourhood: ->(scope, value) { scope.where(neighbourhood: value) },
      min_stars: ->(scope, value) { scope.where(Property.arel_table[:stars].gteq(value.to_i)) },
      amenity: ->(scope, value) { scope.offering(value) },
      max_price_cents: ->(scope, value) { scope.where(Property.from_price_cents.lteq(value.to_i)) }
    }.freeze

    kind :query
    description 'Search hotels, best-rated first: one summary row per hotel, priced from its cheapest room. ' \
                'Pass every constraint the customer gave; `hotel_detail` has the rooms, amenities and address.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   neighbourhood: { type: 'string', enum: Property::NEIGHBOURHOODS, description: 'Istanbul area.' },
                   max_price_cents: { type: 'integer', minimum: 0, maximum: RoomType::MAX_NIGHTLY_PRICE_CENTS,
                                      description: 'Most the cheapest room may cost per night, in cents.' },
                   min_stars: { type: 'integer', minimum: 1, maximum: 5, description: 'Fewest stars.' },
                   amenity: { type: 'string', enum: Property::AMENITIES, description: 'An amenity the hotel must offer.' },
                   limit: { type: 'integer', minimum: 1, maximum: SEARCH_MAX, default: SEARCH_PAGE,
                            description: 'Hotels in one page.' }
                 },
                 required: []
    output_schema '$defs': {
                    hotel: {
                      type: 'object', additionalProperties: false,
                      properties: {
                        property_id: { type: 'integer', description: 'Pass to hotel_detail and availability.' },
                        name: { type: 'string' },
                        neighbourhood: { type: %w[string null], description: 'Istanbul area.' },
                        stars: { type: 'integer' },
                        from_price_cents: { type: %w[integer null],
                                            description: 'Cheapest nightly rate, in cents; null when the hotel lists no rooms.' },
                        room_type_count: { type: 'integer' },
                        currency: { type: 'string', description: 'The currency of the checkout this hotel signs.' }
                      },
                      required: %w[property_id name neighbourhood stars from_price_cents
                                   room_type_count currency]
                    }
                  },
                  type: 'array',
                  description: 'One page of hotels; a `Link` header with rel="next" means more match.',
                  items: { '$ref': '#/$defs/hotel' }
    example_params({ neighbourhood: 'Beşiktaş', min_stars: 4, max_price_cents: 20_000, limit: 20 })
    example_row({
                  property_id: 4, name: 'Bosphorus Palace', neighbourhood: 'Beşiktaş', stars: 5,
                  from_price_cents: 15_000, currency: 'eur', room_type_count: 2
                })
    def search_hotels
      limit  = page_limit
      offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
      scope  = matching_hotels
      hotels = ranked(scope).limit(limit + 1).offset(offset).to_a
      @hotels = hotels.first(limit)

      render_kiosk_page(
        next_cursor: hotels.length > limit ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
        total: scope.count
      )
    end

    private

    # The protocol holds `limit` to the range `input_schema` declares.
    def page_limit = params[:limit] || SEARCH_PAGE

    def matching_hotels
      FILTERS.reduce(Property.all) do |scope, (name, filter)|
        params[name].present? ? filter.call(scope, params[name]) : scope
      end
    end

    # Best-rated first, then cheapest, each row with its price and room count.
    def ranked(scope)
      scope.select(Property.arel_table[Arel.star],
                   Property.from_price_cents.as('from_price_cents'),
                   Property.room_type_count.as('room_type_count'))
           .order(Property.arel_table[:stars].desc, Property.from_price_cents.asc, Property.arel_table[:id].asc)
    end
  end
end
