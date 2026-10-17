# frozen_string_literal: true

# Holds one table for one upcoming seating. A reservation takes no money.
class BookTableOperation
  def self.call(customer_id:, restaurant_table_id:, seating_at:, party_size:)
    table  = RestaurantTable.find(restaurant_table_id)
    booked = "#{table.label} is already booked for that seating; pick another row from availability"
    raise Kiosk::Server::Errors::Conflict, booked if Booking.confirmed.exists?(restaurant_table: table, seating_at:)

    Booking.create!(user_id: customer_id, restaurant_table: table, party_size:, seating_at:, status: :confirmed)
  rescue ActiveRecord::RecordNotUnique
    raise Kiosk::Server::Errors::Conflict, booked
  end
end
