# frozen_string_literal: true

# atablefor's READ surface: the two verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::BookingsController. The one piece of domain logic BOTH halves need, the
# rolling upcoming seatings, was already a library module (lib/seatings.rb) and
# never controller code: `availability` offers a seating and `book_table`
# re-validates against the SAME helper, so the day+time an assistant is shown is
# exactly the one it can book. atablefor is the first demo whose READ half refuses
# at all, and since T-083 nothing about a refusal is written twice: the SENTENCE
# is {WireArguments} (reachable from the write Operations, which render nothing)
# and the RENDERER is {KioskRefusals}, held identical fleet-wide by
# bin/check-demo-copies.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the anti-scalping
# PoW toll and the GUC-scoped transaction live. A route drawn straight here would
# bypass all three, and the mixin answers such a request 404.
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Query
  include KioskRefusals

  # availability — open tables ACROSS the restaurant aggregator for the upcoming
  # rolling seatings that seat the party. Public (no per-user scoping): any
  # authenticated agent may browse. The upcoming seatings (tonight's 19/20/21 in
  # Europe/Lisbon, past ones filtered, rolling to tomorrow) are computed by
  # lib/seatings.rb — so availability is NEVER stale. Tables are FINITE: a table
  # is "open" for a seating only when no CONFIRMED booking already holds it for
  # that exact (table, seating_at); when every table for a seating is taken,
  # availability is legitimately EMPTY for it (honest sell-out).
  #
  # Optional filters. No caller value is ever spliced into SQL: they are ordinary
  # ActiveRecord conditions, so the escaping is the adapter's job and not this
  # handler's (K-654). What that replaced is worth naming, because it is the
  # idiom the review calls "the reference pattern the whole ecosystem copies":
  # `where_nbhd = "AND r.neighborhood = #{conn.quote(nbhd_filter)} "` concatenated
  # into a SELECT, and an `IN (…)` list BUILT by joining quoted timestamps.
  #   :party_size   — only tables seating at least this many (used to size the party)
  #   :neighborhood — restrict to one Lisbon neighbourhood (e.g. "Alfama")
  #   :time         — restrict to one seating time ("19:00" | "20:00" | "21:00")
  #   :date         — restrict to one date (YYYY-MM-DD) among the upcoming seatings
  # The result is small (~5 restaurants × a handful of tables × ≤ a few seatings),
  # so it is NOT paginated.
  description "List open restaurant tables across the aggregator for the " \
              "UPCOMING seatings that seat the party (params: party_size; " \
              "optional neighborhood, time, date filters). Returns one row " \
              "per open (restaurant, table, seating): restaurant, " \
              "neighborhood, cuisine, restaurant_id, restaurant_table_id, " \
              "table_label, capacity, seating_date, seating_time, seating_at, " \
              "deposit_eur. Pass restaurant_id + restaurant_table_id + date + " \
              "time + party_size to book_table (all five are required) — the " \
              "row field named seating_date is book_table's `date` param, and " \
              "the row's seating_time is book_table's `time`: same values, " \
              "different names. Seatings are the current " \
              "upcoming ones (Europe/Lisbon), never stale; a seating with " \
              "every table taken is absent (sold out). deposit_eur is the " \
              "no-show hold in whole EUR (0 = none), settled at the " \
              "restaurant — no online payment. Small; not paginated."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 party_size:   { type: "integer", minimum: 1,
                                 description: "Number of guests." },
                 neighborhood: { type: "string",
                                 description: "Optional Lisbon neighbourhood filter, e.g. \"Alfama\"." },
                 # K-717: a CLOSED SET, so it is an `enum` and not a pattern.
                 # The pattern it replaces accepted "18:00" — a well-formed
                 # time that is not a seating — and the handler answered it
                 # with an empty list, which an assistant cannot tell from a
                 # sold-out night. Declared this way the refusal is the schema
                 # layer's, uniformly, on every verb that names a closed set.
                 time:         { type: "string", enum: Seatings::TIMES,
                                 description: "Optional seating-time filter; one of the seatings this restaurant offers." },
                 date:         { type: "string", format: "date",
                                 description: "Optional date filter, YYYY-MM-DD. Must be among the UPCOMING seatings — the horizon rolls forward daily, so a date outside it is refused with the current ones named." },
               },
               required: ["party_size"]
  # One row per open (restaurant, table, seating). A bare array: this verb is
  # small by construction (~5 restaurants × a handful of tables × ≤ a few
  # seatings) and does not paginate, so there is no `next` and nothing to echo
  # back. `neighborhood` and `cuisine` are the two nullable columns on
  # `restaurants`, and they travel as null rather than being dropped.
  output_schema type: "array",
                description: "Open (restaurant, table, seating) triples, restaurant name then " \
                             "capacity then table label.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    restaurant:          { type: "string", description: "Restaurant name." },
                    neighborhood:        { type: %w[string null], description: "Lisbon neighbourhood, or null." },
                    cuisine:             { type: %w[string null], description: "Cuisine label, or null." },
                    restaurant_id:       { type: "integer", description: "Pass to book_table as `restaurant_id`." },
                    restaurant_table_id: { type: "integer", description: "Pass to book_table as `restaurant_table_id`." },
                    table_label:         { type: "string", description: "The table's in-house label." },
                    capacity:            { type: "integer", description: "Seats at this table." },
                    seating_date:        { type: "string", description: "YYYY-MM-DD — book_table's `date`." },
                    seating_time:        { type: "string", description: "HH:MM (24-hour) — book_table's `time`." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 with offset." },
                    deposit_eur:         { type: "integer", description: "No-show hold in whole EUR (0 = none), settled at the restaurant." },
                  },
                  required: %w[restaurant neighborhood cuisine restaurant_id restaurant_table_id
                               table_label capacity seating_date seating_time seating_at deposit_eur],
                }
  example_params({ party_size: 2, neighborhood: "Alfama" })
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: "2026-08-08", seating_time: "20:00",
    seating_at: "2026-08-08T20:00:00+01:00", deposit_eur: 10,
  })
  def availability
    # An ABSENT party_size and a party_size that is present but unusable are two
    # different mistakes and keep their two different messages: the key check is
    # what the retired `params.fetch(:party_size) { raise }` did, and a present
    # nil still falls through to the >= 1 refusal below exactly as it did. Both
    # sentences live in {WireArguments} — the second one because `book_table`
    # answers with it too, and this half must not be able to drift from that one.
    return render_refusal(WireArguments.missing_party_size) unless params.key?(:party_size)

    party_size, refusal = WireArguments.party_size(params[:party_size])
    return render_refusal(refusal) if refusal

    nbhd_filter = params[:neighborhood].to_s

    # The rolling upcoming seatings (Europe/Lisbon, past filtered, tonight→tomorrow).
    upcoming = Seatings.upcoming

    # K-717: AN INVALID FILTER VALUE IS A TYPED 400 NAMING THE VALID VALUES,
    # NEVER AN EMPTY LIST. Both refusals live in {WireArguments} — see the long
    # note there for why `time` is guarded here as well as declared as an
    # `enum`, and why `date` can only ever be guarded.
    time_filter, refusal = WireArguments.seating_time(params[:time])
    return render_refusal(refusal) if refusal

    date_filter, refusal = WireArguments.seating_date(params[:date], upcoming)
    return render_refusal(refusal) if refusal

    seatings = upcoming
    seatings = seatings.select { |_d, t|   t == time_filter } unless time_filter.empty?
    seatings = seatings.select { |d, _t| d.iso8601 == date_filter } unless date_filter.empty?
    # `return`, and this time it is the RIGHT keyword (K-691). This used to be a
    # block the registry STORED and the Executor `.call`ed long after the
    # initializer's frame was gone, so a top-level `return` raised LocalJumpError
    # — rescued into ActionFailed, i.e. HTTP 500 — and `next []` was the fix. A
    # controller action is an ordinary method, so `return` returns from it: the
    # hazard is gone with the block, and the guard is written the plain way.
    #
    # WHAT REACHES IT NOW is only the honest case. The two ways an INVALID
    # filter used to arrive here — a well-formed `time` that is not a seating,
    # a well-formed `date` past the horizon — are refused above with a typed
    # 400 (K-717). What is left is a filter naming a seating that EXISTS and
    # has simply been overtaken: every one of today's remaining seatings can
    # start while a request is in flight, and then the roster is legitimately
    # empty for a moment. An empty list is the right answer for that, and only
    # for that.
    return render(json: []) if seatings.empty?

    # Every physical table seating >= party, optionally in one neighbourhood.
    # The ORDER BY is Arel rather than a string so the three sort columns stay
    # attributes of the two tables and cannot be mistaken for an injection point.
    catalogue = RestaurantTable
                .joins(:restaurant)
                .where(RestaurantTable.arel_table[:capacity].gteq(party_size))
                .order(Restaurant.arel_table[:name].asc,
                       RestaurantTable.arel_table[:capacity].asc,
                       RestaurantTable.arel_table[:label].asc)
    catalogue = catalogue.where(restaurants: { neighborhood: nbhd_filter }) unless nbhd_filter.empty?

    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names and their order a decision
    # this handler makes rather than a side effect of the schema. One query, no
    # N+1 — the join above already carries the restaurant's name/neighborhood.
    tables = catalogue.pluck(
      "restaurant_tables.id", "restaurant_tables.label", "restaurant_tables.capacity",
      "restaurant_tables.deposit_eur", "restaurants.id", "restaurants.name",
      "restaurants.neighborhood", "restaurants.cuisine",
    )

    # Confirmed holds on any of the upcoming seatings — used to subtract taken
    # (table, seating) pairs so availability sells out honestly. Keyed on the
    # ABSOLUTE instant (UTC epoch seconds) so the match is timezone-agnostic — the
    # seating_at column is timestamptz, and Seatings.seating_at is a zoned Lisbon
    # Time; both reduce to the same epoch, sidestepping session-TZ formatting.
    # The epoch used to be computed by Postgres (`EXTRACT(EPOCH FROM seating_at)`)
    # over an `IN (…)` list this method built by joining quoted literals; the
    # instants are now bound values and `Time#to_i` does the same reduction.
    seating_instants = seatings.map { |d, t| Seatings.seating_at(d, t) }
    taken = {}
    unless seating_instants.empty?
      Booking.confirmed
             .where(seating_at: seating_instants)
             .pluck(:restaurant_table_id, :seating_at)
             .each { |table_id, at| taken["#{table_id}@#{at.to_i}"] = true }
    end

    rows = []
    seatings.each do |date, time|
      seating_at = Seatings.seating_at(date, time)
      key_epoch  = seating_at.to_i
      tables.each do |table_id, table_label, capacity, deposit_eur,
                      restaurant_id, restaurant, neighborhood, cuisine|
        next if taken["#{table_id}@#{key_epoch}"]

        rows << {
          restaurant:          restaurant,
          neighborhood:        neighborhood,
          cuisine:             cuisine,
          restaurant_id:       restaurant_id,
          restaurant_table_id: table_id,
          table_label:         table_label,
          capacity:            capacity,
          seating_date:        date.iso8601,
          seating_time:        time,
          seating_at:          seating_at.iso8601,
          deposit_eur:         deposit_eur,
        }
      end
    end

    render json: rows
  end

  # my_bookings — per-user booking list scoped by the session GUC.
  # The scope is provider-controlled; the agent supplies no filter. This
  # demonstrates app-layer per-user isolation: the principal can only see rows
  # where user_id matches kiosk.current_user_id(), enforced in the query itself —
  # `owned_by_current_principal` is the ONE place that predicate is written, and
  # Booking records why it stays SQL-side (K-654).
  description "List this principal's table bookings across all restaurants " \
              "(scoped to the authenticated user via kiosk.current_user_id()). " \
              "Each row carries a `booking_id`; pass it to cancel_booking as " \
              "`booking_id`."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A bare array, seating-time ordered. `seating_date`/`seating_time` are the
  # seating's LOCAL (Europe/Lisbon) spelling of the same instant `seating_at`
  # carries, which is why all three are always present rather than one being
  # derivable by the assistant.
  output_schema type: "array",
                description: "The principal's bookings, earliest seating first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    booking_id:          { type: "string", description: "Pass to cancel_booking as `booking_id`." },
                    restaurant_id:       { type: "integer", description: "The restaurant the table belongs to." },
                    restaurant:          { type: "string", description: "Restaurant name." },
                    neighborhood:        { type: %w[string null], description: "Lisbon neighbourhood, or null." },
                    restaurant_table_id: { type: "integer", description: "The booked table." },
                    table_label:         { type: "string", description: "The table's in-house label." },
                    party_size:          { type: "integer", description: "Guests the booking holds the table for." },
                    status:              { type: "string", description: "confirmed | cancelled." },
                    seating_date:        { type: "string", description: "YYYY-MM-DD, Europe/Lisbon." },
                    seating_time:        { type: "string", description: "HH:MM (24-hour), Europe/Lisbon." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 with offset." },
                  },
                  required: %w[booking_id restaurant_id restaurant neighborhood restaurant_table_id
                               table_label party_size status seating_date seating_time seating_at],
                }
  def my_bookings
    render json: Booking.owned_by_current_principal
                        .joins(:restaurant, :restaurant_table)
                        .order(:seating_at)
                        .pluck("bookings.id", "bookings.restaurant_id", "restaurants.name",
                               "restaurants.neighborhood", "bookings.restaurant_table_id",
                               "restaurant_tables.label", "bookings.party_size", "bookings.status",
                               "bookings.seating_at")
                        .map { |id, restaurant_id, restaurant, neighborhood,
                                 table_id, table_label, party_size, status, seating_at|
                          # The seating's LOCAL date and time. This was
                          # `to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', …)`
                          # — the zone spelled a second time, in SQL, where a
                          # change to lib/seatings.rb could not reach it. It is
                          # now the same `Seatings.zone` that decides which
                          # seatings exist at all, so the two cannot drift.
                          local = seating_at.in_time_zone(Seatings.zone)
                          { booking_id:          id,
                            restaurant_id:       restaurant_id,
                            restaurant:          restaurant,
                            neighborhood:        neighborhood,
                            restaurant_table_id: table_id,
                            table_label:         table_label,
                            party_size:          party_size,
                            status:              status,
                            seating_date:        local.strftime("%Y-%m-%d"),
                            seating_time:        local.strftime("%H:%M"),
                            seating_at:          Booking.publish_instant(seating_at) }
                        }
  end

end
