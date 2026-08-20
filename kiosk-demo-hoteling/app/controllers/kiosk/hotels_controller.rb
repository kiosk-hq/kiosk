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
  # ADR-0023: semantics only — no argument names and no "pass X to Y as `z`"
  # tail. `output_schema` names each field and points the identifying one at the
  # verbs that take it; naming the follow-on VERB here is the sanctioned form.
  description "Browse the whole hotel catalogue this origin serves. It is small, so it comes back " \
              "entire rather than a page at a time — an empty answer would mean this origin lists no " \
              "hotels at all. Once the human narrows to one, `availability` says which of its room " \
              "types are still free for the nights they want and `reserve_room` takes the hold."
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
  description "Check which room types are still free at ONE hotel for ONE stay. An EMPTY array " \
              "means that hotel is SOLD OUT for those nights, not that it has no rooms — and a hotel " \
              "this origin does not list is 404 not_found rather than an empty answer, so the two are " \
              "never confusable. Rates are quoted per night in EUR cents, but a cart is signed for " \
              "the WHOLE stay at the total the operator quotes, which `reserve_room` returns. Once " \
              "the human picks a room type, `reserve_room` holds it."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id: { type: "integer",
                                description: "Property to check — the `property_id` from a properties row. " \
                                             "An id no property has is 404 not_found." },
                 check_in:    { type: "string", format: "date",
                                description: "First night (YYYY-MM-DD)." },
                 check_out:   { type: "string", format: "date",
                                description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day is " \
                                             "the next guest's check-in day." },
               },
               required: ["property_id", "check_in", "check_out"]
  # A bare array of the room types with NO live booking overlapping the nights
  # asked for — the OFFER, not the catalogue. Empty means the property is sold
  # out for those nights, which is an honest answer and, since T-090, the ONLY
  # thing an empty array means here: an unknown `property_id` is 404.
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

    # T-090 / spec §9.1: `property_id` ADDRESSES a property before anything is
    # filtered — the room types are this property's, not the aggregator's — so
    # an id nobody has is `404 not_found` and NOT an empty list. Empty is
    # reserved for its one honest meaning here: the property exists and is SOLD
    # OUT for the requested nights. This verb answered `200 []` to both until
    # today, which is precisely the pair an assistant cannot tell apart, and it
    # disagreed with `hotel_detail` about the same argument on the same origin.
    refusal = WireArguments.existing_property(property_id)
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
  # ── THE RECONCILIATION SURFACE (K-853) ────────────────────────────────────
  # This is the "per-user query" protocol.md §11.6 sends an assistant to after a
  # `pay` whose response it never read, so what it publishes about money is a
  # normative matter, not a convenience. Until K-853 it published NOTHING about
  # money: an assistant reconciling a lost `pay` learned only that a booking
  # existed and was still `reserved`, which is not an answer — and every gate
  # that DID know about money read the settlement row alone, so it answered "no
  # settlement" about a booking that had already been charged.
  #
  # `payment_state` is the fix and it is a TRI-state on purpose: §11.6 requires
  # a third answer distinct from paid and not-paid, because "no record" is not
  # evidence that no money moved. See {Booking.payment_state}.
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
    # `created_at DESC` with no tiebreaker is what this verb has always ordered
    # by, and it is kept rather than quietly improved: two bookings written in
    # the same microsecond would be free to swap places between runs, but nothing
    # reachable through the wire can produce them, and adding a tiebreaker here
    # would be a behaviour change smuggled into a conversion.
    #
    # The settled flag is a CORRELATED EXISTS over the CALLER's settlements —
    # one statement for the whole list, not one query per row — and it is only
    # the second of the two witnesses {Booking.payment_state} weighs.
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
  # The reference exemplar for the "~100 hotels would overwhelm an unpaginated
  # list" case, and the fleet's ONLY paginating verb: this is the one handler
  # that answers with `render_kiosk_page` instead of `render json:`.
  #
  # SINCE T-092 THAT NO LONGER CHANGES THE BODY. Adopting RFC 8288 moved the
  # opaque cursor into a `Link: <…?cursor=…>; rel="next"` RESPONSE HEADER and
  # the matching-row count into `X-Total-Count`, so this verb answers the same
  # BARE ARRAY as `properties`, `availability` and every other query — the
  # `{"rows": …, "next": …}` object it used to render on a truncated page is
  # gone from the wire and from the declaration below (spec §8.2/§8.4).
  HOTELING_SEARCH_PAGE = 20  # default page size (assistant may override via `limit`)
  HOTELING_SEARCH_MAX  = 50  # cap so `limit` can't defeat pagination

  # ADR-0023, and its ONE carve-out. The filters, their domains and what each
  # one narrows are declared in `input_schema`; the row's fields are in
  # `output_schema`. What stays in prose is the pagination contract — `limit` and
  # `cursor` are RESERVED names a verb never declares (spec §8.1 item 6), so
  # there is no schema for these sentences to duplicate, and a page-size default
  # and its clamp are facts an assistant must have.
  description "Search Istanbul hotels, returning a paginated page of SUMMARY rows — one per hotel, " \
              "priced from its cheapest room. Apply the human's stated constraints as filters so the " \
              "search NARROWS; do not pull the whole catalogue and sift it yourself. Every filter is " \
              "optional and they AND together. Page size defaults to 20 and is CLAMPED to 1..50 — " \
              "send `limit` to override it (a value outside that range is clamped, never refused). " \
              "The BODY is always a bare array; when more hotels match, the response carries a " \
              "`Link` header with rel=\"next\" — fetch that URI verbatim for the following page and " \
              "keep going until there is no such link. X-Total-Count is how many hotels match in " \
              "all, which is how you tell a short page from the end of the results. Prices are EUR " \
              "cents; carts are signed in eur. Once the human picks a row, `hotel_detail` returns " \
              "everything a summary leaves out — the rooms, the amenities, the address."
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
  # ONE SHAPE, and that is the whole of what T-092 bought here. This used to be
  # the only `output_schema` in the fleet with two branches — a `oneOf` over
  # "truncated page = the `{rows, next}` object" and "last page = a bare array"
  # — because the wire had two spellings for a page. RFC 8288 left it one: the
  # cursor is a `Link` header, so a truncated page and a complete one are the
  # SAME array and the declaration says so once. `$defs` is kept because the
  # row shape is worth naming; the union it was reached through is gone.
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

    # `total:` is the ONE extra query T-092 asks for, and it is deliberate: the
    # limit+1 probe above still decides TRUNCATION without a COUNT, but
    # `X-Total-Count` is a statement about the whole matching set and nothing
    # in a page of 21 rows can produce it. The alternative the spec forbids is
    # emitting the page size and calling it the total.
    render_kiosk_page(
      page,
      next_cursor: has_more ? Kiosk::Server::Cursor.encode_offset(offset + limit) : nil,
      total:       scope.count,
    )
  end

  # ── hotel_detail — fetch ONE property by id (search→summaries, fetch on demand)
  description "Fetch the full record for ONE hotel — the «search returns summaries, fetch detail on " \
              "demand» half of this origin's read surface. Call it for the one or few hotels the " \
              "human is choosing between, never across a whole result set. Answers a ONE-ROW array, " \
              "and a hotel this origin does not list is 404 not_found rather than an empty one, " \
              "because the argument ADDRESSES a hotel rather than filtering for one. Rates are EUR " \
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
                                description: "Optional first night (YYYY-MM-DD); pass with check_out to list only free room types." },
                 check_out:   { type: "string", format: "date",
                                description: "Optional checkout day (YYYY-MM-DD, exclusive); pass with check_in to list only free room types." },
               },
               required: ["property_id"]
  # A ONE-ROW ARRAY, not a bare object (K-794, fixed at the 0.4 cutover). Spec
  # §8.2: a query answers a JSON ARRAY of rows — and a detail-by-id query is
  # still a query. Through slice 3 this verb rendered the property object itself
  # and DECLARED `type: "object"`, which was the honest thing to publish about a
  # handler that did that, but it left one verb out of step with its own fleet:
  # getgrocery's and skooti's `kyc_status` each already wrap a single result in a
  # one-row array with the comment «this is a query, and a query answers rows».
  #
  # THE SHAPE AND THE MISS ARE TWO DIFFERENT QUESTIONS, and T-090 separates
  # them. K-794 answered both at once — array shape, and an unknown id as the
  # EMPTY array — and the second half is withdrawn: `property_id` ADDRESSES a
  # property, so an id nobody has is `404 not_found` (spec §9.1). An empty
  # one-row array would state that the property exists and merely has no
  # detail, which is a different and false sentence. The DECLARATION below is
  # unchanged by that: a 404 is a problem document, not a body this schema
  # describes, so the array shape K-794 shipped stands exactly as it was.
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

    # `pick`, not `find_by!`: the bang form raises RecordNotFound and the
    # mixin's `rescue_from` floor would render a 404 with Rails' own message,
    # which says nothing an assistant can act on. The refusal below is the same
    # status with this origin's sentence in it.
    prop = Property.where(id: property_id).pick(:id, :name, :neighbourhood, :stars, :address, :amenities)
    # NO SUCH HOTEL IS 404 (T-090, spec §9.1). `property_id` ADDRESSES a
    # property here — it does not filter one — so an empty array would assert
    # that the property exists and merely has no detail. That is a different
    # sentence from the one `availability` speaks when a property is genuinely
    # sold out, and an assistant that cannot tell them apart retries a lookup
    # that will never succeed. The 404 the wire answers for an UNREGISTERED
    # VERB is not confusable with this one: that one names the verb and carries
    # the registry's hint, this one names the id.
    return render_refusal(WireArguments.property_not_found(property_id)) if prop.nil?

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
