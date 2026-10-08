# frozen_string_literal: true

# Holds one table for one upcoming seating. A reservation takes no money.
class BookTableOperation
  def self.call(principal_id:, restaurant_id:, restaurant_table_id:, date:, time:, party_size:)
    zone       = Restaurant.find_by(id: restaurant_id)&.zone || Seatings.default_zone
    seating_at = WireArguments.seating!(date, time, zone)

    table = RestaurantTable.where(restaurant_id: restaurant_id, capacity: party_size..).find_by(id: restaurant_table_id)
    unless table
      WireArguments.refuse "no such table #{restaurant_table_id} at restaurant #{restaurant_id} seating #{party_size}"
    end

    booked = "table #{restaurant_table_id} is already booked for #{date} #{time}"
    raise Kiosk::Server::Errors::Conflict, booked if Booking.confirmed.exists?(restaurant_table: table, seating_at: seating_at)

    booking = Booking.create!(user_id: principal_id, restaurant_id: restaurant_id, restaurant_table: table,
                              party_size: party_size, seating_at: seating_at, status: :confirmed)

    { booking_id:          booking.id,
      restaurant_id:       restaurant_id,
      restaurant_table_id: restaurant_table_id,
      party_size:          booking.party_size,
      date:                date,
      time:                time,
      seating_label:       Seatings.label(time, zone),
      seating_at:          Booking.publish_instant(seating_at, zone),
      timezone:            zone.name,
      status:              booking.status }
  rescue ActiveRecord::RecordNotUnique
    raise Kiosk::Server::Errors::Conflict, booked
  end
end
