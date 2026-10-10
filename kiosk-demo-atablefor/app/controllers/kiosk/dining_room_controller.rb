# frozen_string_literal: true

# The read verbs.
class Kiosk::DiningRoomController < ApplicationController
  include Kiosk::Handler

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
                 party_size:   { type: "integer", minimum: 1,
                                 maximum: WireArguments::MAX_INT4,
                                 description: "Number of guests." },
                 neighborhood: { type: "string",
                                 description: "Lisbon neighbourhood filter, e.g. \"Alfama\". " \
                                              "Must be one this aggregator serves — an unserved name is " \
                                              "refused with the current ones named." },
                 time:         { type: "string", enum: Seatings::TIMES,
                                 description: "Seating-time filter; one of the seatings this restaurant offers." },
                 date:         { type: "string", format: "date",
                                 description: "Date filter, YYYY-MM-DD. Must be among the UPCOMING seatings — the horizon rolls forward daily, so a date outside it is refused with the current ones named." },
               },
               required: ["party_size"]
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
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: -> { Seatings.default_zone.tomorrow.iso8601 }, seating_time: Seatings::TIMES[1],
    seating_label: "#{Seatings::TIMES[1]} (#{Seatings::DEFAULT_ZONE_NAME})",
    seating_at: -> { Booking.publish_instant(Seatings.seating_at(Seatings.default_zone.tomorrow, Seatings::TIMES[1])) },
    timezone: Seatings::DEFAULT_ZONE_NAME,
    deposit_eur: 10,
  })
  def availability
    party_size   = params[:party_size].to_i
    neighborhood = params[:neighborhood]
    WireArguments.neighborhood!(neighborhood, Restaurant.served_neighborhoods)

    rosters = Restaurant.distinct.pluck(:timezone).to_h { [_1, Seatings.upcoming(zone: Time.find_zone!(_1))] }
    WireArguments.seating_date!(params[:date], rosters.values.flatten(1))

    rosters.transform_values! do |roster|
      roster.select { |date, time| params.fetch(:time, time) == time && params.fetch(:date, date.iso8601) == date.iso8601 }
    end

    tables = RestaurantTable.joins(:restaurant).where(capacity: party_size..)
    tables = tables.where(restaurants: { neighborhood: neighborhood }) if neighborhood.present?

    instants = rosters.flat_map { |name, roster| roster.map { |date, time| Seatings.seating_at(date, time, Time.find_zone!(name)) } }
    taken = Booking.confirmed.where(seating_at: instants).pluck(:restaurant_table_id, :seating_at)
                   .to_set { |table_id, at| [table_id, at.to_i] }

    rows = tables.pluck("restaurant_tables.id", "restaurant_tables.label", "restaurant_tables.capacity",
                        "restaurant_tables.deposit_eur", "restaurants.id", "restaurants.name",
                        "restaurants.neighborhood", "restaurants.cuisine", "restaurants.timezone")
                 .flat_map do |table_id, table_label, capacity, deposit_eur, restaurant_id, restaurant, hood, cuisine, timezone|
      zone = Time.find_zone!(timezone)
      rosters.fetch(timezone).filter_map do |date, time|
        seating_at = Seatings.seating_at(date, time, zone)
        next if taken.include?([table_id, seating_at.to_i])

        { restaurant:          restaurant,
          neighborhood:        hood,
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
          deposit_eur:         deposit_eur }
      end
    end

    render json: rows.sort_by { _1.values_at(:restaurant, :capacity, :table_label, :seating_date, :seating_time) }
  end

  kind :query
  description "List this principal's table bookings across every restaurant on the aggregator, " \
              "scoped to the authenticated account and un-filterable by the caller. Cancelled " \
              "bookings stay listed rather than disappearing, so a booking that was called off is " \
              "distinguishable from one that never existed. Once the human picks a row, " \
              "`cancel_booking` calls it off."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
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
    render json: Booking.own
                        .joins(:restaurant, :restaurant_table)
                        .order(:seating_at)
                        .pluck("bookings.id", "bookings.restaurant_id", "restaurants.name",
                               "restaurants.neighborhood", "bookings.restaurant_table_id",
                               "restaurant_tables.label", "bookings.party_size", "bookings.status",
                               "bookings.seating_at", "restaurants.timezone")
                        .map { |id, restaurant_id, restaurant, neighborhood,
                                 table_id, table_label, party_size, status, seating_at, timezone|
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
