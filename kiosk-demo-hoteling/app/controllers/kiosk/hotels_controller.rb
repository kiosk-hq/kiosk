# frozen_string_literal: true

# The hotel catalogue.

class Kiosk::HotelsController < ActionController::API
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

  SEARCH_PAGE = 20
  SEARCH_MAX  = 50

  kind :query
  description 'Search hotels, best-rated first: one summary row per hotel, priced from its cheapest room. ' \
              'Pass every constraint the customer gave; `hotel_detail` has the rooms, amenities and address.'
  input_schema type: 'object',
               additionalProperties: false,
               properties: {
                 neighbourhood: { type: 'string', enum: NEIGHBOURHOOD_POOL, description: 'Istanbul area.' },
                 max_price_cents: { type: 'integer', minimum: 0, maximum: RoomType::MAX_NIGHTLY_PRICE_CENTS,
                                    description: 'Most the cheapest room may cost per night, in cents.' },
                 min_stars: { type: 'integer', minimum: 1, maximum: 5, description: 'Fewest stars.' },
                 amenity: { type: 'string', enum: AMENITY_POOL, description: 'An amenity the hotel must offer.' }
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
                      currency: { type: 'string', description: 'Sign the cart in this currency.' }
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
    limit  = (params[:limit] || SEARCH_PAGE).to_i.clamp(1, SEARCH_MAX)
    offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])

    scope = Property.all
    scope = scope.where(neighbourhood: params[:neighbourhood]) if params[:neighbourhood].present?
    scope = scope.where(Property.arel_table[:stars].gteq(params[:min_stars].to_i)) if params[:min_stars].present?
    scope = scope.offering(params[:amenity]) if params[:amenity].present?
    scope = scope.where(Property.from_price_cents.lteq(params[:max_price_cents].to_i)) if params[:max_price_cents].present?

    hotels = scope.select(Property.arel_table[Arel.star],
                          Property.from_price_cents.as('from_price_cents'),
                          Property.room_type_count.as('room_type_count'))
                  .order(Property.arel_table[:stars].desc, Property.from_price_cents.asc, Property.arel_table[:id].asc)
                  .limit(limit + 1)
                  .offset(offset)
                  .to_a
    @hotels = hotels.first(limit)

    render_kiosk_page(
      next_cursor: hotels.length > limit ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
      total: scope.count
    )
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
    @property = Property.find(params[:property_id])
    @search   = RoomSearch.new(property: @property, check_in: params[:check_in], check_out: params[:check_out])
    @search.validate!
  end
end
