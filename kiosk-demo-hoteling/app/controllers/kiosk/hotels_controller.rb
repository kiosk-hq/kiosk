# frozen_string_literal: true

# The read verbs.

class Kiosk::HotelsController < ActionController::API
  include Kiosk::Handler

  kind :query
  description "Browse the whole hotel catalogue this origin serves — an empty answer would mean this " \
              "origin lists no hotels at all. Once the human narrows to one, `availability` says " \
              "which of its room types are still free for the nights they want and `reserve_room` " \
              "takes the hold."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The whole (small) catalogue of properties, name-ordered.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    property_id: { type: "integer", description: "Pass to availability, hotel_detail and reserve_room as `property_id`." },
                    name:        { type: "string", description: "Hotel name." },
                    city:        { type: "string", description: "City the property is in." },
                  },
                  required: %w[property_id name city],
                }
  def properties
    render json: Property.order(:name).pluck(:id, :name, :city).map { |id, name, city|
      { property_id: id, name: name, city: city }
    }
  end

  kind :query
  description "Check which room types are still free at ONE hotel for ONE stay. An EMPTY array " \
              "means that hotel is SOLD OUT for those nights, not that it has no rooms. There is no " \
              "availability in the past either: this hotel sells no room-night before tonight, read " \
              "in THE PROPERTY's own clock, which `hotel_detail` publishes as `timezone` and which " \
              "is a fact about the hotel rather than about this operator, and tonight itself IS " \
              "bookable because " \
              "a same-day arrival is an ordinary room-night. " \
              "Rates are quoted PER NIGHT, but a cart is signed for " \
              "the WHOLE stay at the total the operator quotes, which `reserve_room` returns. Once " \
              "the human picks a room type, `reserve_room` holds it."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer",
                                description: "Property to check — the `property_id` from a properties row. " \
                                             "An id no property has is 404 not_found." },
                 check_in:    { type: "string", format: "date",
                                description: "First night (YYYY-MM-DD). Today or later, read in THIS " \
                                             "PROPERTY's own clock (`hotel_detail` publishes it as " \
                                             "`timezone`) — a date before that is refused 400 naming " \
                                             "the earliest night and the zone it was judged on, never " \
                                             "answered with an empty list. A calendar day is never " \
                                             "converted: send the day you mean the hotel to sell." },
                 check_out:   { type: "string", format: "date",
                                description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day is " \
                                             "the next guest's check-in day." },
               },
               required: ["property_id", "check_in", "check_out"]
  output_schema type: "array",
                description: "Room types free for the requested nights, cheapest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    room_type_id:        { type: "integer", description: "Pass to reserve_room as `room_type_id`, with the same `property_id`." },
                    name:                { type: "string", description: "Room-type name." },
                    nightly_price_cents: { type: "integer", description: "EUR cents PER NIGHT — the stay total is nights × this." },
                    currency:            { type: "string", description: "eur — the currency the cart must be signed in." },
                  },
                  required: %w[room_type_id name nightly_price_cents currency],
                }
  def availability
    property_id = params[:property_id].to_i
    check_in    = Date.iso8601(params[:check_in])
    check_out   = Date.iso8601(params[:check_out])
    WireArguments.bookable!(check_in, zone: WireArguments.zone_for(property_id))
    WireArguments.existing_property!(property_id)

    render json: RoomType.where(property_id: property_id)
                         .free_for(property_id, check_in, check_out)
                         .order(:nightly_price_cents)
                         .pluck(:id, :name, :nightly_price_cents)
                         .map { |id, name, cents|
                           { room_type_id: id, name: name, nightly_price_cents: cents, currency: "eur" }
                         }
  end

  kind :query
  description "List this principal's hotel bookings (scoped to authenticated user). " \
              "This is the query to re-read after a payment whose response never arrived: " \
              "each row says where that booking stands with the hotel and where its money " \
              "stands, and a booking whose charge is still outstanding says so rather than " \
              "reporting itself unpaid. A confirmed row also carries the reference the guest " \
              "gives at the desk — the hotel's own record of it, readable at any time and not " \
              "only in the `confirm_booking` answer."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's bookings, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    booking_id:        { type: "string", description: "uuid. Pass to confirm_booking as `booking_id`." },
                    property_id:       { type: "integer", description: "The property booked." },
                    room_type_id:      { type: "integer", description: "The room type held." },
                    check_in:          { type: "string", description: "First night, YYYY-MM-DD." },
                    check_out:         { type: "string", description: "Checkout day (exclusive), YYYY-MM-DD." },
                    total_cents:       { type: "integer", description: "EUR cents for the whole stay." },
                    status:            { type: "string", description: "The room-night's own state: reserved | confirmed | cancelled. It says nothing about money — payment_state does." },
                    payment_state:     { type: "string", enum: %w[unpaid pending paid refunded],
                                         description: "Where this booking's money stands, anchored to the CAPTURE and not to the operator's settlement record. `paid` = the charge went through; there is nothing to retry. `pending` = a capture for this booking has been started and its outcome is not known yet — it may already have taken the money, so do NOT sign a fresh mandate chain: wait and re-read. `unpaid` = no capture has ever been started, and this is the only answer that makes a fresh chain correct. `refunded` = the charge was reversed to the card it came from (a booking the property declined)." },
                    confirmation_code: { type: %w[string null], description: "The reference the guest gives at the desk. Null until the booking is confirmed; durable afterwards." },
                  },
                  required: %w[booking_id property_id room_type_id check_in check_out
                               total_cents status payment_state confirmation_code],
                }
  def my_bookings
    render json: Booking.own.with_settlement(Kiosk::Settlement.own).order(created_at: :desc).map { |booking|
      { booking_id:        booking.id,
        property_id:       booking.property_id,
        room_type_id:      booking.room_type_id,
        check_in:          booking.check_in,
        check_out:         booking.check_out,
        total_cents:       booking.total_cents,
        status:            booking.status,
        payment_state:     booking.payment_state,
        confirmation_code: booking.confirmation_code }
    }
  end

  SEARCH_PAGE = 20
  SEARCH_MAX  = 50

  kind :query
  description "Search Istanbul hotels, returning a paginated page of SUMMARY rows — one per hotel, " \
              "priced from its cheapest room. Apply the human's stated constraints as filters so the " \
              "search NARROWS; do not pull the whole catalogue and sift it yourself. Filters AND " \
              "together. Page size defaults to 20 and is CLAMPED to 1..50 — " \
              "send `limit` to override it (a value outside that range is clamped, never refused). " \
              "Once the human picks a row, `hotel_detail` returns " \
              "everything a summary leaves out — the rooms, the amenities, the address."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 neighbourhood: {
                   type: "string",
                   enum: NEIGHBOURHOOD_POOL,
                   description: "Exact Istanbul area name.",
                 },
                 max_price_cents: {
                   type: "integer", minimum: 0, maximum: WireArguments::MAX_INT4,
                   description: "Cheapest room ≤ this, EUR cents.",
                 },
                 min_stars:       { type: "integer", minimum: 1, maximum: 5, description: "Star-rating floor." },
                 amenity:         { type: "string", enum: AMENITY_POOL, description: "Property must offer this amenity." },
               },
               required: []
  output_schema "$defs": {
                  hotel: {
                    type: "object", additionalProperties: false,
                    description: "One SUMMARY row — one property, its cheapest room's rate.",
                    properties: {
                      property_id:      { type: "integer", description: "Pass to hotel_detail (and reserve_room) as `property_id`." },
                      name:             { type: "string", description: "Hotel name." },
                      neighbourhood:    { type: %w[string null], description: "Istanbul area, or null." },
                      stars:            { type: "integer", description: "Star rating, 1..5." },
                      from_price_cents: { type: %w[integer null], description: "EUR cents per night for the CHEAPEST room type; null when the property lists none." },
                      room_type_count:  { type: "integer", description: "How many room types this property lists." },
                      currency:         { type: "string", description: "eur — the currency the cart must be signed in." },
                    },
                    required: %w[property_id name neighbourhood stars from_price_cents
                                 room_type_count currency],
                  },
                },
                type: "array",
                description: "One page of matching hotels — the same array shape whether or not " \
                             "more match; a `Link` header with rel=\"next\" is what says there are.",
                items: { "$ref": "#/$defs/hotel" }
  example_params({ neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 20000, limit: 20 })
  example_row({
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    from_price_cents: 15000, currency: "eur", room_type_count: 2,
  })
  def search_hotels
    limit  = (params[:limit] || SEARCH_PAGE).to_i.clamp(1, SEARCH_MAX)
    offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])

    scope = Property.all
    scope = scope.where(neighbourhood: params[:neighbourhood]) if params[:neighbourhood].present?
    scope = scope.where(Property.arel_table[:stars].gteq(params[:min_stars].to_i)) if params[:min_stars].present?
    scope = scope.offering(params[:amenity]) if params[:amenity].present?
    if params[:max_price_cents].present?
      scope = scope.where(Property.from_price_cents.lteq(params[:max_price_cents].to_i))
    end

    rows = scope.order(Property.arel_table[:stars].desc, Property.from_price_cents.asc, Property.arel_table[:id].asc)
                .limit(limit + 1)
                .offset(offset)
                .pluck(:id, :name, :neighbourhood, :stars, Property.from_price_cents, Property.room_type_count)

    page = rows.first(limit).map { |id, name, neighbourhood, stars, from_price_cents, room_type_count|
      { property_id:      id,
        name:             name,
        neighbourhood:    neighbourhood,
        stars:            stars,
        from_price_cents: from_price_cents,
        room_type_count:  room_type_count,
        currency:         "eur" }
    }

    render_kiosk_page(
      page,
      next_cursor: rows.length > limit ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
      total:       scope.count,
    )
  end

  kind :query
  description "Fetch the full record for ONE hotel — the «search returns summaries, fetch detail on " \
              "demand» half of this origin's read surface. Call it for the one or few hotels the " \
              "human is choosing between, never across a whole result set. The argument ADDRESSES a " \
              "hotel rather than filtering for one, so the answer is a ONE-ROW array and an id this " \
              "origin does not list is 404 not_found rather than an empty one. THE DATES CHANGE " \
              "WHAT THE ROOM LIST MEANS: give both ends of a stay and the rooms listed are only " \
              "those still FREE " \
              "for those nights — the same rule `availability` applies and `reserve_room` enforces. " \
              "Leave them out and the list is this hotel's full CATALOGUE, which says nothing about " \
              "what is bookable: a room in it may already be taken for the nights you want, and " \
              "`reserve_room` will answer 409."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer", description: "`property_id` from a search_hotels row." },
                 check_in:    { type: "string", format: "date",
                                description: "First night (YYYY-MM-DD); pass with check_out to list only free room types. " \
                                             "When passed it must be today or later in THIS PROPERTY's own clock, which the " \
                                             "row publishes as `timezone` — not this operator's, and not yours. A calendar " \
                                             "day is never converted: send the day you mean the hotel to sell." },
                 check_out:   { type: "string", format: "date",
                                description: "Checkout day (YYYY-MM-DD, exclusive); pass with check_in to list only free room types." },
               },
               required: ["property_id"]
  output_schema type: "array",
                description: "ONE property in full, with its room types — a one-row array. " \
                             "A property_id nobody has is 404 not_found, not an empty array.",
                items: {
                  type: "object",
                  description: "The property.",
                  additionalProperties: false,
                  properties: {
                    property_id:      { type: "integer", description: "The property, echoed." },
                    name:             { type: "string", description: "Hotel name." },
                    neighbourhood:    { type: %w[string null], description: "Istanbul area, or null." },
                    stars:            { type: "integer", description: "Star rating, 1..5." },
                    address:          { type: %w[string null], description: "Street address, or null." },
                    amenities:        { type: "array", items: { type: "string" },
                                        description: "Amenity slugs this property offers." },
                    currency:         { type: "string", description: "eur — the currency the cart must be signed in." },
                    room_types_scope: { type: "string", description: "WHICH list `room_types` is: free for the given nights, or the property's full catalogue when no dates were passed. Read it before treating the list as an offer." },
                    check_in:         { type: %w[string null], description: "The first night the list was computed for, YYYY-MM-DD; null when no dates were passed." },
                    check_out:        { type: %w[string null], description: "The checkout day the list was computed for, YYYY-MM-DD; null when no dates were passed." },
                    timezone:         { type: "string", description: "The IANA zone THIS property's calendar runs on — the clock `check_in` is a day of, and the clock a past date is judged against. It is a property of the hotel, not of this operator: another hotel in the same answer may be on a different one." },
                    room_types:       {
                      type: "array",
                      description: "The property's room types, cheapest first.",
                      items: {
                        type: "object", additionalProperties: false,
                        properties: {
                          room_type_id:        { type: "integer", description: "Pass to reserve_room as `room_type_id`." },
                          name:                { type: "string", description: "Room-type name." },
                          nightly_price_cents: { type: "integer", description: "EUR cents PER NIGHT." },
                        },
                        required: %w[room_type_id name nightly_price_cents],
                      },
                    },
                  },
                  required: %w[property_id name neighbourhood stars address amenities currency
                               room_types_scope check_in check_out timezone room_types],
                }
  example_params({ property_id: 4,
                   check_in:  -> { WireArguments.example_check_in.iso8601 },
                   check_out: -> { WireArguments.example_check_out.iso8601 } })
  example_row({
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    address: "Çırağan Cd. 88, Beşiktaş, Istanbul",
    amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
    currency: "eur",
    room_types_scope: -> {
      "free #{WireArguments.example_check_in.iso8601}..#{WireArguments.example_check_out.iso8601}"
    },
    check_in:  -> { WireArguments.example_check_in.iso8601 },
    check_out: -> { WireArguments.example_check_out.iso8601 },
    timezone:  WireArguments::DEFAULT_ZONE_NAME,
    room_types: [
      { room_type_id: 7, name: "Classic",   nightly_price_cents: 15000 },
      { room_type_id: 8, name: "Bosphorus", nightly_price_cents: 25000 },
    ],
  })
  def hotel_detail
    property_id = params[:property_id].to_i
    dated = params[:check_in].present? || params[:check_out].present?
    if dated
      if params[:check_in].blank? || params[:check_out].blank?
        WireArguments.refuse "check_in and check_out go together — pass both (YYYY-MM-DD) for a free-rooms " \
                             "list, or neither for the property's full catalogue"
      end
      check_in, check_out = WireArguments.stay(params[:check_in], params[:check_out])
      WireArguments.bookable!(check_in, zone: WireArguments.zone_for(property_id))
    end

    property = Property.find_by(id: property_id) or WireArguments.property_not_found!(property_id)
    rooms = property.room_types
    rooms = rooms.free_for(property_id, check_in, check_out) if dated

    render json: [{
      property_id:      property.id,
      name:             property.name,
      neighbourhood:    property.neighbourhood,
      stars:            property.stars,
      address:          property.address,
      amenities:        property.amenities,
      currency:         "eur",
      room_types_scope: dated ? "free #{check_in}..#{check_out}" : "catalogue (no dates given — not an availability statement)",
      check_in:         check_in&.iso8601,
      check_out:        check_out&.iso8601,
      timezone:         property.timezone,
      room_types:       rooms.order(:nightly_price_cents)
                             .pluck(:id, :name, :nightly_price_cents)
                             .map { |id, name, cents| { room_type_id: id, name: name, nightly_price_cents: cents } },
    }]
  end
end
