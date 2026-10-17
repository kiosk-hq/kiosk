# frozen_string_literal: true

# The signed-in customer's table bookings.
class Kiosk::BookingsController < ApplicationController
  include Kiosk::Handler

  BOOKING_ROW = {
    type: "object", additionalProperties: false,
    properties: {
      booking_id:    { type: "string", description: "The booking; pass it to cancel_booking." },
      restaurant:    { type: "string", description: "Restaurant name." },
      neighborhood:  { type: %w[string null], description: "Lisbon neighbourhood." },
      table_label:   { type: "string", description: "The table's name at the restaurant." },
      party_size:    { type: "integer", description: "Guests the table is held for." },
      seating_label: { type: "string", description: "The seating as the human reads it, in the " \
                                                    "restaurant's zone, e.g. \"Sun 18 Oct, 20:00 (Europe/Lisbon)\"." },
      seating_at:    { type: "string", description: "The seating with the restaurant's offset." },
      status:        { type: "string", enum: Booking.statuses.values },
    },
    required: %w[booking_id restaurant neighborhood table_label party_size seating_label seating_at status],
  }.freeze

  kind :query
  description "The signed-in customer's bookings at every restaurant, cancelled ones included. " \
              "`cancel_booking` calls off the one the human picks."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array", description: "Earliest seating first.", items: BOOKING_ROW
  def my_bookings
    render json: Booking.own.includes(:restaurant, :restaurant_table).order(:seating_at).map { row(_1) }
  end

  kind :action
  description "Book a table for an upcoming seating. Nothing is charged. A table already taken for " \
              "that seating is refused as a conflict."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 restaurant_table_id: { type: "integer", minimum: 1,
                                        description: "The table, from an availability row." },
                 seating_at:          { type: "string", format: "date-time",
                                        description: "The seating, from the same availability row." },
                 party_size:          { type: "integer", minimum: 1,
                                        maximum: Booking::MAX_PARTY_SIZE,
                                        description: "Number of guests." },
               },
               required: %w[restaurant_table_id seating_at party_size]
  output_schema BOOKING_ROW.merge(description: "The confirmed booking.")
  example_params({ restaurant_table_id: 1, seating_at: -> { Restaurant.example_seating.iso8601 }, party_size: 2 })
  example_row({
    booking_id: "b1f2a3c4-5d6e-4f70-8a91-2b3c4d5e6f70",
    restaurant: "Tasca do Tejo", neighborhood: "Alfama", table_label: "Window 6", party_size: 2,
    seating_label: -> { Restaurant.seating_label(Restaurant.example_seating) },
    seating_at:    -> { Restaurant.example_seating.iso8601 },
    status: "confirmed",
  })
  def book_table
    render json: row(BookTableOperation.call(
      customer_id:         kiosk_identity.user_id,
      restaurant_table_id: params[:restaurant_table_id].to_i,
      seating_at:          Time.iso8601(params[:seating_at]),
      party_size:          params[:party_size].to_i,
    ))
  end

  kind :action
  description "Cancel one of the signed-in customer's bookings, freeing the table for that seating."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid", description: "The booking to cancel." },
               },
               required: ["booking_id"]
  output_schema type: "object",
                description: "The cancelled booking.",
                additionalProperties: false,
                properties: {
                  booking_id: { type: "string", description: "The booking cancelled." },
                  status:     { type: "string", enum: ["cancelled"] },
                },
                required: %w[booking_id status]
  def cancel_booking
    render json: CancelBookingOperation.call(booking_id: params[:booking_id])
  end

  private

  def row(booking)
    seating = booking.local_seating
    { booking_id:    booking.id,
      restaurant:    booking.restaurant.name,
      neighborhood:  booking.restaurant.neighborhood,
      table_label:   booking.restaurant_table.label,
      party_size:    booking.party_size,
      seating_label: Restaurant.seating_label(seating),
      seating_at:    seating.iso8601,
      status:        booking.status }
  end
end
