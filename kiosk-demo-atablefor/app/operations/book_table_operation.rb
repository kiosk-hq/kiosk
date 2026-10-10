# frozen_string_literal: true

# Holds one table for one upcoming seating. A reservation takes no money.
class BookTableOperation
  def self.call(principal_id:, restaurant_id:, restaurant_table_id:, date:, time:, party_size:)
    restaurant = Restaurant.find(restaurant_id)
    seating_at = restaurant.seating(Date.iso8601(date), time.to_i)

    booked = "table #{restaurant_table_id} is already booked for #{date} #{time}"
    if Booking.confirmed.exists?(restaurant_table_id:, seating_at:)
      raise Kiosk::Server::Errors::Conflict, booked
    end

    booking = Booking.create!(user_id: principal_id, restaurant:, restaurant_table_id:,
                              party_size:, seating_at:, status: :confirmed)

    { booking_id:          booking.id,
      restaurant_id:       restaurant.id,
      restaurant_table_id: restaurant_table_id,
      party_size:          booking.party_size,
      date:                date,
      time:                time,
      seating_label:       Restaurant.seating_label(seating_at),
      seating_at:          seating_at.iso8601,
      timezone:            restaurant.timezone,
      status:              booking.status }
  rescue ActiveRecord::RecordNotUnique
    raise Kiosk::Server::Errors::Conflict, booked
  end
end
