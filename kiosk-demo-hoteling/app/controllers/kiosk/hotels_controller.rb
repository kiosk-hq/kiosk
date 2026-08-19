# frozen_string_literal: true

# hoteling's READ surface: the five verbs an assistant reaches with
# `GET /kiosk/<query-name>`, arguments in the QUERY STRING (protocol 0.4 — the
# multiplexed `POST /kiosk/query` and its `name` field are deleted, not
# deprecated). Kiosk ships a MIXIN, not a base class — `include
# Kiosk::Query` is the whole contract — and each class-level macro records a
# declaration that the NEXT `def` claims, so a method with no macros above it is
# a helper the wire cannot see.
#
# THE SUPERCLASS IS `ActionController::API`, and that is a decision rather than
# an omission. The four earlier slices all inherited from their app's
# `ApplicationController`, which exists in those demos to carry a Devise/CSRF
# signpost for a human sign-in page. hoteling is `config.api_only = true` with no
# Devise and no `ApplicationController` at all; introducing one would add a
# cross-demo lockstep file whose sibling copies exist only for a page this app
# does not serve. The mixin explicitly leaves the base class to the operator
# (K-495), `HomeController` already names its own (`ActionController::Base`, for
# the HTML landing page), and this is the same call one level down. skooti and
# getgrocery are shaped the same way and should follow.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::ReservationsController. What the two halves DO share is their argument
# vocabulary: `property_id` is taken by two queries and one action,
# check_in/check_out by two queries and one action. The shape guard for those is
# {WireArguments} (which renders nothing, so the Operations use it too) and the
# rendering of a refusal is {KioskRefusals}.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here would
# bypass all three, and the mixin answers such a request 404.
class Kiosk::HotelsController < ActionController::API
  include Kiosk::Query
  include KioskRefusals

  # ── properties — the whole (small) catalogue of hotels, name-ordered.
  description "Browse all available hotel properties. Each row carries a " \
              "`property_id`; pass it to availability (and reserve_room) as `property_id`."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
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
    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names and their order a decision
    # this handler makes rather than a side effect of the schema. The column
    # ALIAS the old SELECT carried (`id AS property_id`) becomes an explicit
    # `map`, because `pluck` returns bare tuples.
    render json: Property.order(:name).pluck(:id, :name, :city).map { |id, name, city|
      { property_id: id, name: name, city: city }
    }
  end

  # ── availability — the OFFER: room types of one property with no live booking
  # overlapping the requested nights. `RoomType.free_for` is that predicate, and
  # `reserve_room` sells against the same scope, so the two cannot disagree
  # (K-690).
  description "Check room availability at a property for given dates. Each row carries a " \
              "`room_type_id` (pass it to reserve_room as `room_type_id`, along with the " \
              "same `property_id`). nightly_price_cents is EUR cents per night — carts must " \
              "be signed in eur at the operator-quoted total (nights × nightly_price_cents)"
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer",
                                description: "Property to check — the `property_id` from a properties row." },
                 check_in:    { type: "string", format: "date",
                                description: "First night (YYYY-MM-DD)." },
                 check_out:   { type: "string", format: "date",
                                description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day is " \
                                             "the next guest's check-in day." },
               },
               required: ["property_id", "check_in", "check_out"]
  # A bare array of the room types with NO live booking overlapping the nights
  # asked for — the OFFER, not the catalogue. Empty means the property is sold
  # out for those nights, which is an honest answer and the only thing an empty
  # array means here.
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

    check_in, check_out = dates
    # The pricing currency is advertised on every row so an external assistant
    # knows to sign its cart in EUR (the cashier check rejects any other currency
    # at capture). It is appended last, exactly where the old `rows.each` put it.
    render json: RoomType.where(property_id: property_id)
                         .free_for(property_id, check_in, check_out)
                         .order(:nightly_price_cents)
                         .pluck(:id, :name, :nightly_price_cents)
                         .map { |id, name, cents|
                           { room_type_id: id, name: name, nightly_price_cents: cents, currency: "eur" }
                         }
  end

  # ── my_bookings — per-identity: the caller's OWN bookings only. The caller
  # supplies no filter; the scope is provider-controlled and un-bypassable.
  # `owned_by_current_principal` is the ONE place the identity predicate is
  # written — see Booking for why it stays SQL-side.
  description "List this principal's hotel bookings (scoped to authenticated user). " \
              "Each row carries a `booking_id`; pass it to confirm_booking as `booking_id`. " \
              "A confirmed row also carries the `confirmation_code` the hotel has on " \
              "file for it — the reference the guest gives at the desk — so it can be " \
              "read back at any time, not only in the confirm_booking response. " \
              "It is null until the booking is confirmed."
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
                    status:            { type: "string", description: "reserved | confirmed | cancelled." },
                    confirmation_code: { type: %w[string null], description: "The reference the guest gives at the desk. Null until the booking is confirmed; durable afterwards." },
                  },
                  required: %w[booking_id property_id room_type_id check_in check_out
                               total_cents status confirmation_code],
                }
  def my_bookings
    # `created_at DESC` with no tiebreaker is what this verb has always ordered
    # by, and it is kept rather than quietly improved: two bookings written in
    # the same microsecond would be free to swap places between runs, but nothing
    # reachable through the wire can produce them, and adding a tiebreaker here
    # would be a behaviour change smuggled into a conversion.
    render json: Booking.owned_by_current_principal
                        .order(created_at: :desc)
                        .pluck(:id, :property_id, :room_type_id, :check_in, :check_out,
                               :total_cents, :status, :confirmation_code)
                        .map { |id, property_id, room_type_id, check_in, check_out,
                                total_cents, status, confirmation_code|
                          { booking_id:        id,
                            property_id:       property_id,
                            room_type_id:      room_type_id,
                            check_in:          check_in,
                            check_out:         check_out,
                            total_cents:       total_cents,
                            status:            status,
                            confirmation_code: confirmation_code }
                        }
  end

  # ── search_hotels — paginated, multi-parameter search (T-042 / K-452) ────────
  #
  # The reference exemplar for the "~100 hotels would overwhelm an unpaginated
  # list" case, and the fleet's ONLY paginating verb: this is the one handler that
  # answers with `render_kiosk_page` instead of a bare array, which is how the
  # opaque `next` cursor reaches the response at all. 0.4 retired the envelope
  # but not the page: a TRUNCATED answer is the object `{"rows": …, "next": …}`
  # and a COMPLETE one is the bare array every other query answers, because
  # `next` ABSENT is what "last page" means and an array has nowhere to put a
  # cursor ({Kiosk::Server::Result#to_payload}).
  HOTELING_SEARCH_PAGE = 20  # default page size (assistant may override via `limit`)
  HOTELING_SEARCH_MAX  = 50  # cap so `limit` can't defeat pagination

  description "Search Istanbul hotels with optional filters, returning a paginated " \
              "page of SUMMARY rows (one row per property, cheapest room's nightly " \
              "rate). Apply the user's stated constraints as filters; do not fetch " \
              "the whole catalogue. All filters are optional and AND together: " \
              "neighbourhood (exact area name), max_price_cents (cheapest room ≤ this, " \
              "EUR cents), min_stars (star rating ≥ this), amenity (property must offer " \
              "it). Page size defaults to 20 and is CLAMPED to 1..50 — send `limit` to " \
              "override it (a value outside that range is clamped, never refused); when " \
              "the response carries a top-level `next`, more hotels match — echo it back " \
              "verbatim as `cursor` to fetch the following page, and keep paging until " \
              "`next` is absent. from_price_cents is EUR cents (carts are signed in eur). " \
              "Each row carries a `property_id`; pass it to hotel_detail as `property_id` " \
              "for the full property (rooms, amenities, address)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 neighbourhood: {
                   type: "string",
                   enum: %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                            Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı],
                   description: "Exact Istanbul area name.",
                 },
                 max_price_cents: { type: "integer", minimum: 0, description: "Cheapest room ≤ this, EUR cents." },
                 min_stars:       { type: "integer", minimum: 1, maximum: 5, description: "Star-rating floor." },
                 amenity:         { type: "string", enum: AMENITY_POOL, description: "Property must offer this amenity." },
               },
               # `limit` and `cursor` ARE NOT DECLARED HERE, and their absence is the
               # declaration (K-798). Spec §8.1 item 6 and §8.4 make them RESERVED names
               # the wire always accepts and a verb never declares, precisely so a
               # schema shows an assistant this verb's BUSINESS parameters only (T-087,
               # 2026-08-19). The engine honours a declaration as the more specific
               # statement, so declaring them was never broken — it just made the fleet's
               # one paginating verb the one place the text and the tree disagreed, and
               # made the derived OpenAPI document publish hoteling's own pair instead of
               # the generic injected one. Nothing about the handler changed: the decoder
               # still coerces `limit` to an integer and `cursor` to a string from
               # ArgumentDecoder::RESERVED, the validator exempts an UNDECLARED reserved
               # name from `additionalProperties: false`, and the OpenAPI renderer injects
               # both into this operation. The 1..50 clamp the declaration used to carry
               # lives where an assistant reads it — in `description` above, next to the
               # 20/50 defaults — and, as before, in the handler, which clamps rather
               # than refuses.
               required: []
  # THE FLEET'S ONLY PAGINATING VERB, and its output_schema is the only one in
  # the fleet with two branches — because the wire has two spellings for a page
  # and both are conformant (spec §8.4). A TRUNCATED page is the object
  # `{rows, next}`; a COMPLETE one is a bare array, because `next` ABSENT is
  # what "this is the last page" means and an array has nowhere to put a cursor.
  # An assistant that always pages until `next` is gone reads both correctly;
  # one that assumed an object would break on the last page, which is exactly
  # what a declaration is for.
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
                description: "One page of matching hotels.",
                oneOf: [
                  { type: "array",
                    description: "The last (or only) page: no `next`, so no more hotels match.",
                    items: { "$ref": "#/$defs/hotel" } },
                  { type: "object", additionalProperties: false,
                    description: "A truncated page: more hotels match.",
                    properties: {
                      rows: { type: "array", items: { "$ref": "#/$defs/hotel" },
                              description: "This page's hotels." },
                      next: { type: "string",
                              description: "An OPAQUE cursor. Echo it back verbatim as `cursor` for the following page; never parse or construct it." },
                    },
                    required: %w[rows next] },
                ]
  example_params({ neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 20000, limit: 20 })
  example_row({
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    from_price_cents: 15000, currency: "eur", room_type_count: 2,
  })
  def search_hotels
    # Scalars are read through `to_s` before `to_i` rather than straight `to_i`:
    # a JSON `true` or `[3]` has no `to_i` and used to raise NoMethodError, i.e. a
    # 500 for an off-schema value the descriptor already forbids. Every value the
    # schema DOES allow reads the same as before.
    limit = params[:limit].to_s.strip.empty? ? HOTELING_SEARCH_PAGE : params[:limit].to_s.to_i
    limit = HOTELING_SEARCH_PAGE if limit <= 0
    limit = HOTELING_SEARCH_MAX  if limit > HOTELING_SEARCH_MAX

    # A cursor is OPAQUE by contract and `Cursor.decode_offset` is deliberately
    # lenient — garbage decodes to the first page rather than raising. The clamp
    # extends that promise to the one input it did not cover: a cursor that
    # decodes to a NEGATIVE offset used to reach Postgres and come back
    # "OFFSET must not be negative", a 500 for a value the assistant is told never
    # to read or construct.
    offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
    offset = 0 if offset.negative?

    scope = Property.all
    scope = scope.where(neighbourhood: params[:neighbourhood].to_s) if params[:neighbourhood].present?
    scope = scope.where(Property.arel_table[:stars].gteq(params[:min_stars].to_s.to_i)) if params[:min_stars].present?
    scope = scope.offering(params[:amenity].to_s) if params[:amenity].present?
    if params[:max_price_cents].present?
      scope = scope.where(Property.from_price_cents.lteq(params[:max_price_cents].to_s.to_i))
    end

    # Fetch limit+1 to detect a following page without a second COUNT query.
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

    render_kiosk_page(
      page,
      next_cursor: has_more ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
    )
  end

  # ── hotel_detail — fetch ONE property by id (search→summaries, fetch on demand)
  description "Fetch the full detail for ONE hotel by its `property_id` (the same " \
              "`property_id` a search_hotels row carries): name, neighbourhood, stars, " \
              "address, amenities, and its room types (each carries a `room_type_id` for " \
              "reserve_room) with their nightly rates. Answers a ONE-ROW array; an EMPTY " \
              "array means no property has that id. This is " \
              "the \"search returns summaries, fetch detail on demand\" pattern — call it " \
              "for the one or few hotels the user is choosing between, not for the whole " \
              "result set. nightly_price_cents is EUR cents (carts are signed in eur). " \
              "DATES: pass check_in AND check_out (both, YYYY-MM-DD) to get only the room " \
              "types still FREE for those nights — the same rule `availability` applies and " \
              "reserve_room enforces. WITHOUT dates the room_types list is this property's " \
              "full CATALOGUE, not a statement about what is bookable: a room type listed " \
              "there may already be taken for your nights, and reserve_room will answer 409."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer", description: "`property_id` from a search_hotels row." },
                 check_in:    { type: "string", format: "date",
                                description: "Optional first night (YYYY-MM-DD); pass with check_out to list only free room types." },
                 check_out:   { type: "string", format: "date",
                                description: "Optional checkout day (YYYY-MM-DD, exclusive); pass with check_in to list only free room types." },
               },
               required: ["property_id"]
  # A ONE-ROW ARRAY, not a bare object (K-794, fixed at the 0.4 cutover). Spec
  # §8.2: a query that does not paginate answers a JSON ARRAY of rows — and a
  # detail-by-id query is still a query. Through slice 3 this verb rendered the
  # property object itself and DECLARED `type: "object"`, which was the honest
  # thing to publish about a handler that did that, but it left one verb out of
  # step with its own fleet: getgrocery's and skooti's `kyc_status` each already
  # wrap a single result in a one-row array with the comment «this is a query,
  # and a query answers with rows».
  #
  # The array is not bookkeeping. "No such hotel" now has an answer inside the
  # contract — the EMPTY array — instead of needing a 404 or a null the schema
  # would have to admit; and an assistant that reads every query the same way
  # (iterate the rows) does not need a special case for this one.
  output_schema type: "array",
                description: "ONE property in full, with its room types — a one-row array, " \
                             "empty when no property has that id.",
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
  example_params({ property_id: 4, check_in: "2026-09-01", check_out: "2026-09-04" })
  example_row({
    property_id: 4, name: "Bosphorus Palace", neighbourhood: "Beşiktaş", stars: 5,
    address: "Çırağan Cd. 88, Beşiktaş, Istanbul",
    amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
    currency: "eur",
    room_types_scope: "free 2026-09-01..2026-09-04",
    check_in: "2026-09-01", check_out: "2026-09-04",
    room_types: [
      { room_type_id: 7, name: "Classic",   nightly_price_cents: 15000 },
      { room_type_id: 8, name: "Bosphorus", nightly_price_cents: 25000 },
    ],
  })
  def hotel_detail
    return unless kiosk_present?(params[:property_id], "property_id")

    # ── Optional date filter (K-690) ─────────────────────────────────────────
    # Without dates this query listed EVERY room type of a property with no
    # booking filter at all, so an assistant that went search → hotel_detail →
    # reserve_room (skipping `availability`) was reading a catalogue as if it were
    # an offer, and reserved rooms that were already sold. Given both dates it
    # re-applies `availability`'s exclusion — the SAME `RoomType.free_for` scope,
    # not a second copy of the predicate; given neither it says so in the
    # descriptor and in the response.
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
      # `Date.parse`, NOT {WireArguments.stay_dates}'s stricter `Date.iso8601`,
      # and deliberately so: this verb has ALWAYS parsed its dates in Ruby, so
      # what it accepts and refuses is already published behaviour and is not
      # this conversion's to change. The two verbs disagreeing about what a date
      # string is, is worth converging — as a decision, not as a side effect of a
      # conversion.
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
    end

    property_id, refusal = WireArguments.integer(params[:property_id], field: "property_id",
                                                                       hint: WireArguments::HINT_PROPERTY_ID)
    return render_refusal(refusal) if refusal

    # `pick`, not `find_by!`: the bang form raises RecordNotFound, which Rails
    # maps to a 404 the mixin's `rescue_from` floor would render — and since
    # K-794 an unknown id is not an error on this verb at all, so a raise here
    # would put back exactly the answer the array shape removed.
    prop = Property.where(id: property_id).pick(:id, :name, :neighbourhood, :stars, :address, :amenities)
    # NO SUCH HOTEL IS THE EMPTY ARRAY, not a 404 (K-794). This verb used to
    # refuse `not_found` — the only `not_found` hoteling ever produced. On a
    # query that answers rows, "nothing matched the id you filtered by" is what
    # an empty result MEANS, and it is the same sentence `availability` already
    # speaks when a property is sold out. An assistant that iterates the rows
    # of every query needs no branch for this one, and there is no status to
    # confuse with the 404 the wire itself answers for an UNREGISTERED VERB.
    return render json: [] if prop.nil?

    rooms = RoomType.where(property_id: property_id)
    rooms = rooms.free_for(property_id, ci, co) if dated
    # `amenities` is jsonb; ActiveRecord's type already hands back a Ruby Array,
    # so the "normalise regardless of driver decoding" JSON.parse the raw handler
    # carried has no work left to do.
    #
    # ONE ROW IN AN ARRAY (K-794) — the brackets are the whole fix. §8.2 says a
    # query that does not paginate answers an array of rows, and one row is
    # still rows.
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

  # Presence guard as a guard clause —
  #
  #   return unless kiosk_present?(params[:property_id], "property_id")
  #
  # — so the refusal is already rendered when the action returns. An argument
  # that is ABSENT has always been answered this way; one that is PRESENT but
  # null or empty used to reach Postgres as `''::integer`/`''::date` and come
  # back a 500.
  def kiosk_present?(value, field)
    return true if value.present?

    render_refusal(WireArguments.missing(field))
    false
  end
end
