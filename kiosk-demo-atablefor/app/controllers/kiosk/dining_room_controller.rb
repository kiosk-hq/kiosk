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
              "confirms it; everything it needs is on that row."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 party_size:   { type: "integer", minimum: 1,
                                 maximum: Booking::MAX_PARTY_SIZE,
                                 description: "Number of guests." },
                 neighborhood: { type: "string",
                                 description: "Lisbon neighbourhood filter, e.g. \"Alfama\". " \
                                              "Must be one this aggregator serves — an unserved name is " \
                                              "refused with the current ones named." },
                 time:         { type: "string", enum: Restaurant.seating_times,
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
                                                                        "e.g. \"20:00 (Europe/Lisbon)\". The wall clock " \
                                                                        "is THE RESTAURANT's, not this aggregator's and not yours; " \
                                                                        "`seating_at` carries the same instant with its resolved offset." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                    timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator: another restaurant in the same answer may be on a different one." },
                  },
                  required: %w[restaurant neighborhood cuisine restaurant_id restaurant_table_id
                               table_label capacity seating_date seating_time seating_label seating_at
                               timezone],
                }
  example_params({ party_size: 2, neighborhood: "Alfama" })
  example_row({
    restaurant: "Tasca do Tejo", neighborhood: "Alfama",
    cuisine: "Portuguese tavern", restaurant_id: 1,
    restaurant_table_id: 1, table_label: "Window 6", capacity: 2,
    seating_date: -> { Time.find_zone!("Europe/Lisbon").tomorrow.iso8601 }, seating_time: "20:00",
    seating_label: "20:00 (Europe/Lisbon)",
    seating_at: -> { Time.find_zone!("Europe/Lisbon").now.tomorrow.change(hour: 20).iso8601 },
    timezone: "Europe/Lisbon",
  })
  def availability
    search = TableSearch.new(params.permit(:party_size, :neighborhood, :date, :time))
    search.validate!

    restaurants = search.restaurants.to_a
    taken = Booking.confirmed.where(restaurant: restaurants, seating_at: Time.current..)
                   .pluck(:restaurant_table_id, :seating_at).to_set

    render json: restaurants.flat_map { |restaurant|
      restaurant.restaurant_tables.to_a.product(search.seatings(restaurant))
                .reject { |table, seating| taken.include?([table.id, seating]) }
                .map { |table, seating| open_table(restaurant, table, seating) }
    }
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
                                                                        "e.g. \"20:00 (Europe/Lisbon)\"." },
                    seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                    timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator." },
                  },
                  required: %w[booking_id restaurant_id restaurant neighborhood restaurant_table_id
                               table_label party_size status seating_date seating_time seating_label
                               seating_at timezone],
                }
  def my_bookings
    render json: Booking.own.includes(:restaurant, :restaurant_table).order(:seating_at).map { |booking|
      seating = booking.local_seating
      { booking_id:          booking.id,
        restaurant_id:       booking.restaurant_id,
        restaurant:          booking.restaurant.name,
        neighborhood:        booking.restaurant.neighborhood,
        restaurant_table_id: booking.restaurant_table_id,
        table_label:         booking.restaurant_table.label,
        party_size:          booking.party_size,
        status:              booking.status,
        seating_date:        seating.to_date.iso8601,
        seating_time:        seating.strftime("%H:%M"),
        seating_label:       Restaurant.seating_label(seating),
        seating_at:          seating.iso8601,
        timezone:            booking.restaurant.timezone }
    }
  end

  private

  def open_table(restaurant, table, seating)
    { restaurant:          restaurant.name,
      neighborhood:        restaurant.neighborhood,
      cuisine:             restaurant.cuisine,
      restaurant_id:       restaurant.id,
      restaurant_table_id: table.id,
      table_label:         table.label,
      capacity:            table.capacity,
      seating_date:        seating.to_date.iso8601,
      seating_time:        seating.strftime("%H:%M"),
      seating_label:       Restaurant.seating_label(seating),
      seating_at:          seating.iso8601,
      timezone:            restaurant.timezone }
  end
end
