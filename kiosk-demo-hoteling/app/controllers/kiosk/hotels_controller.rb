# frozen_string_literal: true

# hoteling's READ surface: the five verbs an assistant reaches with
# `GET /kiosk/<query-name>`, arguments in the QUERY STRING. Kiosk ships a MIXIN,
# not a base class — `include Kiosk::Handler` is the whole contract — and each
# class-level macro records a declaration that the NEXT `def` claims, so a
# method with no macros above it is a helper the wire cannot see.
#
# The superclass is `ActionController::API` and not an `ApplicationController`:
# hoteling is `config.api_only = true` with no Devise and no
# ApplicationController at all, and the mixin leaves the base class to the
# operator (K-495).
#
# `kind :query` is what puts a declaration on `GET`, and the kind belongs to the
# DECLARATION rather than the class (K-921), so one controller may declare both
# — keeping the write half next door in Kiosk::ReservationsController is this
# demo's shape, not a rule. The two halves share an argument vocabulary: the
# shape guard is {WireArguments} (which renders nothing, so the Operations use
# it too) and rendering a refusal is {KioskRefusals}.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, where authentication, the registration PoW gate
# and the GUC-scoped transaction live. A route drawn straight here would bypass
# all three, and the mixin answers such a request 404.
class Kiosk::HotelsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # ── properties — the whole (small) catalogue of hotels, name-ordered.
  # ADR-0023: the `description` carries semantics only; fields live in the schema.
  kind :query
  description "Browse the whole hotel catalogue this origin serves — an empty answer would mean this " \
              "origin lists no hotels at all. Once the human narrows to one, `availability` says " \
              "which of its room types are still free for the nights they want and `reserve_room` " \
              "takes the hold."
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
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
    # `pluck` rather than loading models: a projection, and naming the columns is
    # what keeps the wire's field names and their order a decision this handler
    # makes rather than a side effect of the schema.
    render json: Property.order(:name).pluck(:id, :name, :city).map { |id, name, city|
      { property_id: id, name: name, city: city }
    }
  end

  # ── availability — the OFFER: room types of one property with no live booking
  # overlapping the requested nights. `RoomType.free_for` is that predicate, and
  # `reserve_room` sells against the same scope, so the two cannot disagree (K-690).
  kind :query
  description "Check which room types are still free at ONE hotel for ONE stay. An EMPTY array " \
              "means that hotel is SOLD OUT for those nights, not that it has no rooms. There is no " \
              "availability in the past either: this hotel sells no room-night before tonight, read " \
              "in the property's own clock (Europe/Istanbul), and tonight itself IS bookable because " \
              "a same-day arrival is an ordinary room-night. " \
              "Rates are quoted per night in EUR cents, but a cart is signed for " \
              "the WHOLE stay at the total the operator quotes, which `reserve_room` returns. Once " \
              "the human picks a room type, `reserve_room` holds it."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer",
                                description: "Property to check — the `property_id` from a properties row. " \
                                             "An id no property has is 404 not_found." },
                 check_in:    { type: "string", format: "date",
                                description: "First night (YYYY-MM-DD). Today or later, read in the " \
                                             "property's own clock (Europe/Istanbul) — a date before " \
                                             "that is refused 400 naming the earliest night, never " \
                                             "answered with an empty list." },
                 check_out:   { type: "string", format: "date",
                                description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day is " \
                                             "the next guest's check-in day." },
               },
               required: ["property_id", "check_in", "check_out"]
  # The OFFER, not the catalogue. Empty means the property is sold out for those
  # nights and, since T-090, that is the ONLY thing empty means here — an unknown
  # `property_id` is 404.
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
    return unless kiosk_present?(params[:property_id], "property_id")
    return unless kiosk_present?(params[:check_in], "check_in")
    return unless kiosk_present?(params[:check_out], "check_out")

    property_id, refusal = WireArguments.integer(params[:property_id], field: "property_id",
                                                                       hint: WireArguments::HINT_PROPERTY_ID)
    return render_refusal(refusal) if refusal

    dates, refusal = WireArguments.stay_dates(params[:check_in], params[:check_out])
    return render_refusal(refusal) if refusal

    # K-969: a past `check_in` is outside this verb's domain (§9.1's first
    # branch), so it is a named 400 rather than the `[]` that already means SOLD
    # OUT here — the two must not be confusable. `reserve_room` refuses the same
    # class from the same guard.
    refusal = WireArguments.past_stay(dates.first)
    return render_refusal(refusal) if refusal

    # T-090 / spec §9.1: `property_id` ADDRESSES a property before anything is
    # filtered, so an id nobody has is `404 not_found` and NOT an empty list —
    # empty is reserved for its one honest meaning here, that the property exists
    # and is SOLD OUT for the requested nights.
    refusal = WireArguments.existing_property(property_id)
    return render_refusal(refusal) if refusal

    check_in, check_out = dates
    # The currency is advertised on every row so an assistant knows to sign its
    # cart in EUR (the cashier rejects any other currency at capture).
    render json: RoomType.where(property_id: property_id)
                         .free_for(property_id, check_in, check_out)
                         .order(:nightly_price_cents)
                         .pluck(:id, :name, :nightly_price_cents)
                         .map { |id, name, cents|
                           { room_type_id: id, name: name, nightly_price_cents: cents, currency: "eur" }
                         }
  end

  # ── my_bookings — per-identity: the caller's OWN bookings only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable, and
  # `owned_by_current_principal` is the ONE place the identity predicate is
  # written (see Booking for why it stays SQL-side).
  #
  # THE RECONCILIATION SURFACE (K-853): this is the "per-user query" protocol.md
  # §11.6 sends an assistant to after a `pay` whose response it never read, so
  # what it publishes about money is normative. `payment_state` is a TRI-state on
  # purpose — §11.6 requires a third answer distinct from paid and not-paid,
  # because "no record" is not evidence that no money moved.
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
                    payment_state:     { type: "string", enum: %w[unpaid pending paid],
                                         description: "Where this booking's money stands, anchored to the CAPTURE and not to the operator's settlement record. `paid` = the charge went through; there is nothing to retry. `pending` = a capture for this booking has been started and its outcome is not known yet — it may already have taken the money, so do NOT sign a fresh mandate chain: wait and re-read. `unpaid` = no capture has ever been started, and this is the only answer that makes a fresh chain correct." },
                    confirmation_code: { type: %w[string null], description: "The reference the guest gives at the desk. Null until the booking is confirmed; durable afterwards." },
                  },
                  required: %w[booking_id property_id room_type_id check_in check_out
                               total_cents status payment_state confirmation_code],
                }
  def my_bookings
    # The settled flag is a CORRELATED EXISTS over the CALLER's settlements — one
    # statement for the whole list, not one query per row — and it is only the
    # second of the two witnesses {Booking.payment_state} weighs.
    settled_flag = Booking.settled_flag(Settlement.of_current_principal)
    render json: Booking.owned_by_current_principal
                        .order(created_at: :desc)
                        .pluck(:id, :property_id, :room_type_id, :check_in, :check_out,
                               :total_cents, :status, :payment_status, settled_flag,
                               :confirmation_code)
                        .map { |id, property_id, room_type_id, check_in, check_out,
                                total_cents, status, payment_status, settled, confirmation_code|
                          { booking_id:        id,
                            property_id:       property_id,
                            room_type_id:      room_type_id,
                            check_in:          check_in,
                            check_out:         check_out,
                            total_cents:       total_cents,
                            status:            status,
                            payment_state:     Booking.payment_state(payment_status, settled),
                            confirmation_code: confirmation_code }
                        }
  end

  # ── search_hotels — paginated, multi-parameter search (T-042 / K-452) ────────
  #
  # The fleet's ONLY paginating verb: the one handler that answers with
  # `render_kiosk_page`. Per RFC 8288 the opaque cursor rides in a
  # `Link: <…?cursor=…>; rel="next"` header and the matching-row count in
  # `X-Total-Count`, so the BODY is the same bare array every other query
  # answers (spec §8.2/§8.4).
  HOTELING_SEARCH_PAGE = 20  # default page size (assistant may override via `limit`)
  HOTELING_SEARCH_MAX  = 50  # cap so `limit` can't defeat pagination

  # The «what should I have sent» tails for this verb's three INTEGER arguments
  # (K-1025). {WireArguments.integer} takes a hint because a refusal that only
  # says «not an integer» leaves the caller to guess the domain; each of these
  # names it, and `limit`'s names the clamp so a caller does not read its
  # refusal as «this page size is too big».
  HINT_SEARCH_LIMIT     = "`limit` is a whole number of rows, e.g. 20. It is CLAMPED to " \
                          "1..#{HOTELING_SEARCH_MAX} — an integer outside that range is adjusted, " \
                          "never refused; this refusal is about the SHAPE."
  HINT_SEARCH_MIN_STARS = "`min_stars` is a whole number 1..5 — the star rating to floor at."
  HINT_SEARCH_MAX_PRICE = "`max_price_cents` is a whole number of EUR CENTS, e.g. 20000 for €200."

  # ADR-0023, and its ONE carve-out. The filters and the row's fields are
  # declared in the schemas. The page-size default, its clamp and `X-Total-Count`
  # stay in prose because no schema can hold them: `limit` and `cursor` are
  # RESERVED names a verb never declares (spec §8.1 item 6). How to FOLLOW a
  # `rel="next"` link is not here — the skill states that once, for every
  # operator.
  kind :query
  description "Search Istanbul hotels, returning a paginated page of SUMMARY rows — one per hotel, " \
              "priced from its cheapest room. Apply the human's stated constraints as filters so the " \
              "search NARROWS; do not pull the whole catalogue and sift it yourself. Every filter is " \
              "optional and they AND together. Page size defaults to 20 and is CLAMPED to 1..50 — " \
              "send `limit` to override it (a value outside that range is clamped, never refused). " \
              "X-Total-Count is how many hotels match in " \
              "all, which is how you tell a short page from the end of the results. Prices are EUR " \
              "cents; carts are signed in eur. Once the human picks a row, `hotel_detail` returns " \
              "everything a summary leaves out — the rooms, the amenities, the address."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 neighbourhood: {
                   type: "string",
                   enum: NEIGHBOURHOOD_POOL,
                   description: "Exact Istanbul area name.",
                 },
                 max_price_cents: { type: "integer", minimum: 0, description: "Cheapest room ≤ this, EUR cents." },
                 min_stars:       { type: "integer", minimum: 1, maximum: 5, description: "Star-rating floor." },
                 amenity:         { type: "string", enum: AMENITY_POOL, description: "Property must offer this amenity." },
               },
               # `limit` and `cursor` ARE NOT DECLARED HERE, and their absence is the
               # declaration (K-798): spec §8.1 item 6 and §8.4 make them RESERVED names
               # the wire always accepts and a verb never declares, so a schema shows an
               # assistant this verb's BUSINESS parameters only. The decoder still coerces
               # them, the validator exempts them from `additionalProperties: false`, and
               # the OpenAPI renderer injects both into this operation.
               required: []
  # ONE SHAPE: the cursor is a `Link` header, so a truncated page and a complete
  # one are the SAME array and the declaration says so once. `$defs` is kept
  # because the row shape is worth naming.
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
    # ── THE THREE INTEGERS THIS VERB READS GO THROUGH THE DEMO'S OWN GUARD ────
    #
    # K-1025. They used to read `params[…].to_s.to_i`, and `to_s` before `to_i`
    # is enough to stop the `NoMethodError` a JSON `true` or `[3]` would raise
    # on a bare `.to_i` — it is NOT enough to agree with the `{type: "integer"}`
    # declared in front of them. `.to_i` answers 0 for `"abc"` and 1 for
    # `"1.5"`, so a junk filter became «no floor at all» or a floor nobody
    # asked for, silently, and a junk `limit` became the default page size. This
    # demo already WROTE DOWN its answer to that exact question one file over:
    # {WireArguments.integer} is `Integer(raw, 10)` with base 10 explicit so
    # `"0x10"` is refused rather than read as 16, and it is what `property_id`
    # and `room_type_id` have always used. These three were the only readers of
    # a declared integer on this surface that bypassed it.
    #
    # NOT REACHABLE FROM THE WIRE — said out loud rather than left as a puzzle.
    # `search_hotels` is `kind :query`, so {Kiosk::Server::ArgumentDecoder} has
    # already coerced `min_stars` and `max_price_cents` (both declared
    # `type: "integer"`) and `limit` (a RESERVED name it coerces to integer by
    # default, spec §8.1 item 6) through the SAME strict `Integer(v, 10)`: a
    # `1.5`, a `true` or an array is a typed 400 before this method runs. That is
    # precisely why the second layer had to be fixed rather than left — a layer
    # that only holds while the layer in front of it holds is not a second layer.
    #
    # THE CLAMP IS UNCHANGED, and it is what the description publishes: every
    # INTEGER `limit` is adjusted into 1..HOTELING_SEARCH_MAX and never refused.
    # A non-integer is not «a value outside that range» — it is not a page size
    # at all, and the engine in front of this line already answers it 400.
    limit = HOTELING_SEARCH_PAGE
    if params[:limit].present?
      requested, refusal = WireArguments.integer(params[:limit], field: "limit",
                                                                 hint: HINT_SEARCH_LIMIT)
      return render_refusal(refusal) if refusal

      limit = requested
    end
    limit = HOTELING_SEARCH_PAGE if limit <= 0
    limit = HOTELING_SEARCH_MAX  if limit > HOTELING_SEARCH_MAX

    # A cursor is OPAQUE by contract and `Cursor.decode_offset` is deliberately
    # lenient — garbage decodes to the first page. The clamp covers the one input
    # it does not: a NEGATIVE offset, which Postgres answers with a 500.
    offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
    offset = 0 if offset.negative?

    # The filters, in the order they have always been applied — a refusal is
    # raised where the filter is read, so `{min_stars: "abc", max_price_cents:
    # "abc"}` still answers about `min_stars` first.
    scope = Property.all
    scope = scope.where(neighbourhood: params[:neighbourhood].to_s) if params[:neighbourhood].present?
    if params[:min_stars].present?
      min_stars, refusal = WireArguments.integer(params[:min_stars], field: "min_stars",
                                                                     hint: HINT_SEARCH_MIN_STARS)
      return render_refusal(refusal) if refusal

      scope = scope.where(Property.arel_table[:stars].gteq(min_stars))
    end
    scope = scope.offering(params[:amenity].to_s) if params[:amenity].present?
    if params[:max_price_cents].present?
      max_price_cents, refusal = WireArguments.integer(params[:max_price_cents],
                                                       field: "max_price_cents",
                                                       hint:  HINT_SEARCH_MAX_PRICE)
      return render_refusal(refusal) if refusal

      scope = scope.where(Property.from_price_cents.lteq(max_price_cents))
    end

    # Fetch limit+1 to detect a following page without counting the whole set.
    rows = scope.order(Property.arel_table[:stars].desc,
                       Property.from_price_cents.asc,
                       Property.arel_table[:id].asc)
                .limit(limit + 1)
                .offset(offset)
                .pluck(:id, :name, :neighbourhood, :stars,
                       Property.from_price_cents, Property.room_type_count)

    has_more = rows.length > limit
    page = rows.first(limit).map { |id, name, neighbourhood, stars, from_price_cents, room_type_count|
      { property_id:      id,
        name:             name,
        neighbourhood:    neighbourhood,
        stars:            stars,
        from_price_cents: from_price_cents,
        room_type_count:  room_type_count,
        currency:         "eur" }
    }

    # `total:` is one extra query, deliberately: the limit+1 probe decides
    # TRUNCATION without a COUNT, but `X-Total-Count` is a statement about the
    # whole matching set, which no page of 21 rows can produce.
    render_kiosk_page(
      page,
      next_cursor: has_more ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
      total:       scope.count,
    )
  end

  # ── hotel_detail — fetch ONE property by id (search→summaries, fetch on demand)
  kind :query
  description "Fetch the full record for ONE hotel — the «search returns summaries, fetch detail on " \
              "demand» half of this origin's read surface. Call it for the one or few hotels the " \
              "human is choosing between, never across a whole result set. The argument ADDRESSES a " \
              "hotel rather than filtering for one, so the answer is a ONE-ROW array and an id this " \
              "origin does not list is 404 not_found rather than an empty one. Rates are EUR " \
              "cents; carts are signed in eur. THE DATES ARE OPTIONAL AND THEY CHANGE WHAT THE ROOM " \
              "LIST MEANS: give both ends of a stay and the rooms listed are only those still FREE " \
              "for those nights — the same rule `availability` applies and `reserve_room` enforces. " \
              "Leave them out and the list is this hotel's full CATALOGUE, which says nothing about " \
              "what is bookable: a room in it may already be taken for the nights you want, and " \
              "`reserve_room` will answer 409."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer", description: "`property_id` from a search_hotels row." },
                 check_in:    { type: "string", format: "date",
                                description: "Optional first night (YYYY-MM-DD); pass with check_out to list only free room types. " \
                                             "When passed it must be today or later in the property's clock (Europe/Istanbul)." },
                 check_out:   { type: "string", format: "date",
                                description: "Optional checkout day (YYYY-MM-DD, exclusive); pass with check_in to list only free room types." },
               },
               required: ["property_id"]
  # A ONE-ROW ARRAY, not a bare object (K-794). Spec §8.2: a query answers a JSON
  # ARRAY of rows, and a detail-by-id query is still a query. The MISS is a
  # separate question from the SHAPE (T-090): an id nobody has is `404 not_found`
  # (spec §9.1), because an empty one-row array would state that the property
  # exists and merely has no detail.
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
                               room_types_scope check_in check_out room_types],
                }
  # THE STAY IS RESOLVED, NOT WRITTEN DOWN (K-972). A calendar literal here ages
  # into a 400, because a `check_in` before today is REFUSED. `example_params`
  # and `example_row` are RESOLVABLE slots (see {Kiosk::Server::SchemaSlots}), so
  # both name {WireArguments.example_check_in}/{WireArguments.example_check_out},
  # and `room_types_scope` is built from the same two rather than repeating them.
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
    room_types: [
      { room_type_id: 7, name: "Classic",   nightly_price_cents: 15000 },
      { room_type_id: 8, name: "Bosphorus", nightly_price_cents: 25000 },
    ],
  })
  def hotel_detail
    return unless kiosk_present?(params[:property_id], "property_id")

    # ── Optional date filter (K-690) ─────────────────────────────────────────
    # With both dates this applies `availability`'s exclusion — the SAME
    # `RoomType.free_for` scope, not a second copy of the predicate. Without them
    # the list is a CATALOGUE, and the response says so rather than implying an
    # offer.
    ci_raw = params[:check_in].to_s.strip
    co_raw = params[:check_out].to_s.strip
    dated  = !ci_raw.empty? && !co_raw.empty?
    if !dated && (!ci_raw.empty? || !co_raw.empty?)
      return render_refusal(OperationResult.refused(
        code:    "bad_request",
        message: "check_in and check_out go together — pass both (YYYY-MM-DD) for a free-rooms " \
                 "list, or neither for the property's full catalogue",
      ))
    end
    if dated
      # `Date.parse`, NOT {WireArguments.stay_dates}'s stricter `Date.iso8601`:
      # what this verb accepts is already published behaviour. Converging the two
      # is worth doing as a decision, not as a side effect.
      ci, co = begin
        [Date.parse(ci_raw), Date.parse(co_raw)]
      rescue ArgumentError, TypeError
        return render_refusal(OperationResult.refused(
          code:    "bad_request",
          message: "invalid check_in/check_out: #{ci_raw.inspect}/#{co_raw.inspect} — use YYYY-MM-DD",
        ))
      end
      unless co > ci
        return render_refusal(OperationResult.refused(
          code: "bad_request", message: "check_out must be after check_in",
        ))
      end
      # K-969: WITH dates this verb becomes an availability statement, so a past
      # `check_in` would publish a free-rooms list for nights nobody can book.
      # Same guard as `availability` and `reserve_room` — one floor per origin.
      refusal = WireArguments.past_stay(ci)
      return render_refusal(refusal) if refusal
    end

    property_id, refusal = WireArguments.integer(params[:property_id], field: "property_id",
                                                                       hint: WireArguments::HINT_PROPERTY_ID)
    return render_refusal(refusal) if refusal

    # `pick`, not `find_by!`: the bang form's RecordNotFound would render a 404
    # carrying Rails' own message, which says nothing an assistant can act on.
    # The refusal below is the same status with this origin's sentence in it.
    prop = Property.where(id: property_id).pick(:id, :name, :neighbourhood, :stars, :address, :amenities)
    # NO SUCH HOTEL IS 404 (T-090, spec §9.1). Not confusable with the 404 the
    # wire answers for an UNREGISTERED VERB: that one names the verb and carries
    # the registry's hint, this one names the id.
    return render_refusal(WireArguments.property_not_found(property_id)) if prop.nil?

    rooms = RoomType.where(property_id: property_id)
    rooms = rooms.free_for(property_id, ci, co) if dated
    # `amenities` is jsonb and ActiveRecord already hands back a Ruby Array. The
    # brackets are K-794's one-row array: §8.2, a query answers rows.
    render json: [{
      property_id:      prop[0],
      name:             prop[1],
      neighbourhood:    prop[2],
      stars:            prop[3],
      address:          prop[4],
      amenities:        prop[5],
      currency:         "eur",
      # Says which of the two things the list is, so a reader of the response
      # alone (not the descriptor) cannot mistake a catalogue for an offer.
      room_types_scope: dated ? "free #{ci}..#{co}" : "catalogue (no dates given — not an availability statement)",
      check_in:         dated ? ci.to_s : nil,
      check_out:        dated ? co.to_s : nil,
      room_types:       rooms.order(:nightly_price_cents)
                             .pluck(:id, :name, :nightly_price_cents)
                             .map { |id, name, cents|
                               { room_type_id: id, name: name, nightly_price_cents: cents }
                             },
    }]
  end

  private

  # Presence guard as a guard clause: `return unless kiosk_present?(…)`, so the
  # refusal is already rendered when the action returns.
  def kiosk_present?(value, field)
    return true if value.present?

    render_refusal(WireArguments.missing(field))
    false
  end
end
