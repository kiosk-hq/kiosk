# frozen_string_literal: true

# The write verbs. The work is in app/operations.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler

  kind :action
  description "Book a specific restaurant table for a chosen upcoming " \
              "seating, for the authenticated principal. Confirms the " \
              "reservation outright: there is no hold to release and nothing " \
              "is charged. Contention is real and finite, so a " \
              "table already held for that seating is refused as a clean " \
              "conflict rather than double-booked, and so is a seating that " \
              "has already passed. Every value it needs is on the " \
              "availability row the human picked."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 restaurant_id:       { type: "integer", minimum: 1,
                                        description: "The restaurant_id from an availability row." },
                 restaurant_table_id: { type: "integer", minimum: 1,
                                        description: "The restaurant_table_id from an availability row." },
                 date:                { type: "string", format: "date",
                                        description: "The seating_date (YYYY-MM-DD) from the availability row." },
                 time:                { type: "string", enum: Restaurant.seating_times,
                                        description: "The seating_time HH:MM (24-hour), e.g. \"20:00\"." },
                 party_size:          { type: "integer", minimum: 1,
                                        maximum: Booking::MAX_PARTY_SIZE,
                                        description: "Number of guests." },
               },
               required: ["restaurant_id", "restaurant_table_id", "date", "time", "party_size"]
  output_schema type: "object",
                description: "The confirmed booking.",
                additionalProperties: false,
                properties: {
                  booking_id:          { type: "string", description: "Pass to cancel_booking as `booking_id`." },
                  restaurant_id:       { type: "integer", description: "The restaurant booked." },
                  restaurant_table_id: { type: "integer", description: "The table held." },
                  party_size:          { type: "integer", description: "Guests the booking holds the table for." },
                  date:                { type: "string", description: "The seating date, YYYY-MM-DD, on the restaurant's own clock — the row publishes it as `timezone`." },
                  time:                { type: "string", description: "The seating time, HH:MM (24-hour) on THE RESTAURANT's own clock, " \
                                                                      "published as `timezone` — the table is there, so that is the " \
                                                                      "clock. `seating_at` is the same instant with its resolved " \
                                                                      "offset; `seating_label` is this time with the zone written " \
                                                                      "beside it." },
                  seating_label:       { type: "string", description: "The seating rendered for a human, IN THE ZONE IT NAMES — " \
                                                                      "e.g. \"20:00 (Europe/Lisbon)\". This is the line " \
                                                                      "to read back to the human: `time` alone is a bare wall clock." },
                  seating_at:          { type: "string", description: "The seating instant, ISO 8601 carrying THIS RESTAURANT's offset — every verb of this demo publishes this field on the clock of the restaurant the row is about." },
                  timezone:            { type: "string", description: "The IANA zone this row is rendered in — a property of the RESTAURANT, not of this aggregator." },
                  status:              { type: "string", description: "confirmed." },
                },
                required: %w[booking_id restaurant_id restaurant_table_id party_size
                             date time seating_label seating_at timezone status]
  example_params({
    restaurant_id: 1, restaurant_table_id: 1,
    date: -> { Time.find_zone!("Europe/Lisbon").tomorrow.iso8601 }, time: "20:00", party_size: 2,
  })
  example_row({
    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
    restaurant_id: 1, restaurant_table_id: 1, party_size: 2,
    date: -> { Time.find_zone!("Europe/Lisbon").tomorrow.iso8601 }, time: "20:00",
    seating_label: "20:00 (Europe/Lisbon)",
    seating_at: -> { Time.find_zone!("Europe/Lisbon").now.tomorrow.change(hour: 20).iso8601 },
    timezone: "Europe/Lisbon",
    status: "confirmed",
  })
  def book_table
    render json: BookTableOperation.call(
      principal_id:        kiosk_identity.user_id,
      restaurant_id:       params[:restaurant_id].to_i,
      restaurant_table_id: params[:restaurant_table_id].to_i,
      date:                params[:date],
      time:                params[:time],
      party_size:          params[:party_size].to_i,
    )
  end

  kind :action
  description "Cancel one of the authenticated principal's own table bookings " \
              "(requires the booking to belong to the principal). Frees the (table, seating)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid",
                               description: "The booking to cancel — a `booking_id` from " \
                                            "book_table or my_bookings, verbatim; it must " \
                                            "belong to the principal." },
               },
               required: ["booking_id"]
  output_schema type: "object",
                description: "The cancelled booking.",
                additionalProperties: false,
                properties: {
                  booking_id: { type: "string", description: "The booking that was cancelled, echoed." },
                  status:     { type: "string", description: "cancelled." },
                },
                required: %w[booking_id status]
  def cancel_booking
    render json: CancelBookingOperation.call(booking_id: params[:booking_id])
  end
end
