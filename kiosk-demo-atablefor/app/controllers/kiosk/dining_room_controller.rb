# frozen_string_literal: true

# atablefor's READ surface: the two verbs an assistant reaches with
# `GET /kiosk/<query-name>` — one endpoint per verb since 0.4, arguments in the
# query string. Kiosk ships a MIXIN, not a base class: the superclass is this
# app's own ApplicationController and `include Kiosk::Handler` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot
# see; `kind :query` is what puts a declaration on `GET`, and the kind belongs
# to the DECLARATION rather than the class, so one controller may
# declare both. Splitting the halves is this demo's shape, not a rule: the
# writes live in Kiosk::BookingsController, the refusal SENTENCES in
# {WireArguments} and the RENDERER in {KioskRefusals}, and the rolling upcoming
# seatings both halves need are a library module (app/models/seatings.rb), so
# what `availability` offers is exactly what `book_table` accepts.
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # availability — open tables ACROSS the aggregator for the upcoming rolling
  # seatings that seat the party. Public: any authenticated agent may browse, no
  # per-user scoping. The upcoming seatings (19/20/21 on EACH RESTAURANT's own
  # clock, past ones filtered, rolling to tomorrow) come from
  # app/models/seatings.rb, so availability is NEVER stale. Tables are FINITE:
  # a table is "open" for a seating only when no CONFIRMED booking holds it for
  # that exact (table, seating_at), so a fully-booked seating is legitimately
  # absent.
  #
  # No caller value is ever spliced into SQL — the filters below are ordinary
  # ActiveRecord conditions. The result is small and NOT paginated.
  # The description carries semantics only; `input_schema` declares
  # what each filter accepts and refuses, `output_schema` names every row field.
  kind :query
  description "List open restaurant tables across the aggregator for the " \
              "UPCOMING seatings that can seat the party. One row per open " \
              "(restaurant, table, seating), so an EMPTY array means what you " \
              "asked for is genuinely sold out. Seatings are the current " \
              "upcoming ones on EACH RESTAURANT's own clock — the `timezone` " \
              "field of a row names it — never stale, and one with every " \
              "table taken is absent. Once the human picks a row, `book_table` " \
              "confirms it; everything it needs is on that row. Any deposit " \
              "shown is a no-show hold settled at the restaurant — this origin " \
              "takes no online payment."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 # THE SAME DECLARED CEILING `book_table` carries —
                 # a party this verb would SHOW a table for is one that verb can
                 # book, so the two descriptors have to agree. It is the width of
                 # `restaurant_tables.capacity`, the column the filter compares
                 # against, and not an invented house limit.
                 party_size:   { type: "integer", minimum: 1,
                                 maximum: WireArguments::MAX_INT4,
                                 description: "Number of guests." },
                 # The served set is DB-derived (an operator adds one by
                 # inserting a restaurant), so it cannot be an `enum` here and
                 # the handler guard is the only place the refusal can live.
                 neighborhood: { type: "string",
                                 description: "Lisbon neighbourhood filter, e.g. \"Alfama\". " \
                                              "Must be one this aggregator serves — an unserved name is " \
                                              "refused with the current ones named." },
                 # A CLOSED SET, so an `enum` and not a pattern — the
                 # refusal is then the schema layer's, uniformly, rather than an
                 # empty list an assistant cannot tell from a sold-out night.
                 time:         { type: "string", enum: Seatings::TIMES,
                                 description: "Seating-time filter; one of the seatings this restaurant offers." },
                 date:         { type: "string", format: "date",
                                 description: "Date filter, YYYY-MM-DD. Must be among the UPCOMING seatings — the horizon rolls forward daily, so a date outside it is refused with the current ones named." },
               },
               required: ["party_size"]
  # One row per open (restaurant, table, seating). A bare array: this verb does
  # not paginate, so there is no `next` and nothing to echo back. `neighborhood`
  # and `cuisine` are nullable and travel as null rather than being dropped.
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
                    seating_time:        { type: "string", description: "HH:MM (24-hour) on THIS restaurant's clock, which the row publishes as `timezone` — book_table's `time`." },
                    seating_label:       { type: "string", description: "The seating rendered for a human, IN THE ZONE IT NAMES — " \
                                                                        "e.g. \"20:00 (#{Seatings::DEFAULT_ZONE_NAME})\". The wall clock " \
                                                                        "is THE RESTAURANT's, not this aggregator's and not yours; " \
                                                                        "`seating_at` carries the same instant with its resolved offset." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                    timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator: another restaurant in the same answer may be on a different one." },
                    deposit_eur:         { type: "integer", description: "No-show hold in whole EUR (0 = none), settled at the restaurant." },
                  },
                  required: %w[restaurant neighborhood cuisine restaurant_id restaurant_table_id
                               table_label capacity seating_date seating_time seating_label seating_at
                               timezone deposit_eur],
                }
  example_params({ party_size: 2, neighborhood: "Alfama" })
  # The seating is RESOLVED, not written down: this row is what an
  # assistant carries straight into `book_table`, whose own guard refuses a
  # seating that has passed. See {Seatings.example_date}.
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: -> { Seatings.example_date.iso8601 }, seating_time: Seatings::TIMES[1],
    seating_label: "#{Seatings::TIMES[1]} (#{Seatings::DEFAULT_ZONE_NAME})",
    seating_at: -> { Booking.publish_instant(Seatings.seating_at(Seatings.example_date, Seatings.example_time)) },
    timezone: Seatings::DEFAULT_ZONE_NAME,
    deposit_eur: 10,
  })
  def availability
    # An ABSENT party_size and a present-but-unusable one are two different
    # mistakes with two different messages. Both sentences live in
    # {WireArguments} — the second because `book_table` answers with it too, and
    # the two halves must not drift.
    return render_refusal(WireArguments.missing_party_size) unless params.key?(:party_size)

    party_size, refusal = WireArguments.party_size(params[:party_size])
    return render_refusal(refusal) if refusal

    # An unserved neighbourhood is a typed 400 naming the served ones,
    # not `200 []`. `Restaurant.served_neighborhoods` is read once, so the
    # refusal and the query below can never name different sets.
    nbhd_filter, refusal = WireArguments.neighborhood(params[:neighborhood],
                                                      Restaurant.served_neighborhoods)
    return render_refusal(refusal) if refusal

    # ── ONE ROSTER PER RESTAURANT CLOCK ──────────────────────────────────
    #
    # A seating exists at a restaurant, on that restaurant's calendar, so the
    # rolling horizon is computed PER ZONE and not once for the origin. At one
    # instant a Lisbon restaurant may still be offering tonight's 21:00 while a
    # restaurant two hours east has rolled to tomorrow — and both answers are
    # correct. `distinct.pluck` because the roster depends only on the ZONE, so
    # a hundred restaurants in one city cost one computation.
    rosters  = Restaurant.distinct.pluck(:timezone).to_h { |name|
      [name, Seatings.upcoming(zone: Time.find_zone!(name))]
    }
    # What the `date` filter is validated against: the UNION of every listed
    # restaurant's horizon. A date that is bookable at one of them is a date
    # this verb must accept, and the per-restaurant filtering below is what
    # decides whose tables it can actually offer.
    upcoming = rosters.values.flatten(1).uniq

    # An invalid filter value is a typed 400 NAMING the valid values,
    # never an empty list. Both refusals live in {WireArguments}.
    time_filter, refusal = WireArguments.seating_time(params[:time])
    return render_refusal(refusal) if refusal

    date_filter, refusal = WireArguments.seating_date(params[:date], upcoming)
    return render_refusal(refusal) if refusal

    # The filters apply INSIDE each restaurant's own roster, so a row survives
    # only when the seating is still open at the restaurant offering it.
    rosters = rosters.transform_values { |roster|
      roster = roster.select { |_d, t| t == time_filter }         unless time_filter.empty?
      roster = roster.select { |d, _t| d.iso8601 == date_filter } unless date_filter.empty?
      roster
    }
    seatings = rosters.values.flatten(1).uniq
    # Only an HONEST empty reaches here: an invalid `time` or `date` was refused
    # above with a typed 400, so what is left is a seating that exists and was
    # overtaken while the request was in flight.
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
    # columns keeps the wire's field names and their order this handler's
    # decision. One query, no N+1 — the join already carries the restaurant.
    tables = catalogue.pluck(
      "restaurant_tables.id", "restaurant_tables.label", "restaurant_tables.capacity",
      "restaurant_tables.deposit_eur", "restaurants.id", "restaurants.name",
      "restaurants.neighborhood", "restaurants.cuisine", "restaurants.timezone",
    )

    # Confirmed holds on the upcoming seatings, subtracted below so availability
    # sells out honestly. Keyed on the ABSOLUTE instant (UTC epoch seconds) so
    # the match is timezone-agnostic: `seating_at` is timestamptz and
    # Seatings.seating_at is a Time zoned to the restaurant, and both reduce to
    # one epoch — which is what lets restaurants on two clocks share one lookup.
    seating_instants = rosters.flat_map { |name, roster|
      zone = Time.find_zone!(name)
      roster.map { |d, t| Seatings.seating_at(d, t, zone) }
    }.uniq
    taken = {}
    unless seating_instants.empty?
      Booking.confirmed
             .where(seating_at: seating_instants)
             .pluck(:restaurant_table_id, :seating_at)
             .each { |table_id, at| taken["#{table_id}@#{at.to_i}"] = true }
    end

    # THE OUTER LOOP IS THE TABLE, not the seating, because the seating a table
    # can be offered for is decided by ITS OWN restaurant's roster. Written the
    # other way round, one origin-wide roster would be crossed with every table
    # — which is exactly the shape that made this demo answer a hundred
    # restaurants on one clock.
    rows = []
    tables.each do |table_id, table_label, capacity, deposit_eur,
                    restaurant_id, restaurant, neighborhood, cuisine, timezone|
      zone = Time.find_zone!(timezone)
      rosters.fetch(timezone, []).each do |date, time|
        seating_at = Seatings.seating_at(date, time, zone)
        next if taken["#{table_id}@#{seating_at.to_i}"]

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
          seating_label:       Seatings.label(time, zone),
          seating_at:          Booking.publish_instant(seating_at, zone),
          timezone:            timezone,
          deposit_eur:         deposit_eur,
        }
      end
    end
    # The ORDER the catalogue query established is restaurant name, then
    # capacity, then table label; crossing tables with rosters preserves it
    # within a table but no longer groups by seating, so it is re-established
    # here on the same three keys plus the seating, which is what a reader of
    # the published order expects.
    rows.sort_by! { |r| [r[:restaurant], r[:capacity], r[:table_label], r[:seating_date], r[:seating_time]] }

    render json: rows
  end

  # my_bookings — per-user booking list scoped by the session GUC. The scope is
  # provider-controlled; the agent supplies no filter. The principal can only
  # see rows where user_id matches kiosk.current_user_id(), enforced in the
  # query itself — `owned_by_current_principal` is the ONE place that predicate
  # is written.
  # Semantics only; naming the follow-on VERB in the description is
  # the sanctioned form, naming its argument is not.
  kind :query
  description "List this principal's table bookings across every restaurant on the aggregator, " \
              "scoped to the authenticated account and un-filterable by the caller. Cancelled " \
              "bookings stay listed rather than disappearing, so a booking that was called off is " \
              "distinguishable from one that never existed. Once the human picks a row, " \
              "`cancel_booking` calls it off."
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A bare array, seating-time ordered. `seating_date`/`seating_time` are the
  # spelling of the same instant `seating_at` carries, read on THE RESTAURANT's
  # own clock, so all three are always present rather than one being derivable
  # — and `timezone` says which clock, per row, because two bookings in one
  # answer may be at restaurants in two cities.
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
                    seating_date:        { type: "string", description: "YYYY-MM-DD on the restaurant's own clock, which this row publishes as `timezone`." },
                    seating_time:        { type: "string", description: "HH:MM (24-hour) on the restaurant's own clock, which this row publishes as `timezone`." },
                    seating_label:       { type: "string", description: "The seating rendered for a human, IN THE ZONE IT NAMES — " \
                                                                        "e.g. \"20:00 (#{Seatings::DEFAULT_ZONE_NAME})\"." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                    timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator." },
                  },
                  required: %w[booking_id restaurant_id restaurant neighborhood restaurant_table_id
                               table_label party_size status seating_date seating_time seating_label
                               seating_at timezone],
                }
  def my_bookings
    render json: Booking.owned_by_current_principal
                        .joins(:restaurant, :restaurant_table)
                        .order(:seating_at)
                        .pluck("bookings.id", "bookings.restaurant_id", "restaurants.name",
                               "restaurants.neighborhood", "bookings.restaurant_table_id",
                               "restaurant_tables.label", "bookings.party_size", "bookings.status",
                               "bookings.seating_at", "restaurants.timezone")
                        .map { |id, restaurant_id, restaurant, neighborhood,
                                 table_id, table_label, party_size, status, seating_at, timezone|
                          # The seating's LOCAL date and time, read on THE
                          # RESTAURANT's own clock — the same zone that decides
                          # which seatings exist there at all, so the two cannot
                          # drift, and a second restaurant in this same answer
                          # is read on a different one.
                          zone  = Time.find_zone!(timezone)
                          local = seating_at.in_time_zone(zone)
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
                            seating_label:       Seatings.label(local.strftime("%H:%M"), zone),
                            seating_at:          Booking.publish_instant(seating_at, zone),
                            timezone:            timezone }
                        }
  end

end
