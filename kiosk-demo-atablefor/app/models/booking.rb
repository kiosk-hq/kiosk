# frozen_string_literal: true

# One principal holding one table for one seating. Cancelling frees the
# (table, seating): the unique index `idx_bookings_confirmed_table_seating`
# covers confirmed rows only.
class Booking < ApplicationRecord
  include Kiosk::Owned

  enum :status, { confirmed: "confirmed", cancelled: "cancelled" }

  belongs_to :user
  belongs_to :restaurant
  belongs_to :restaurant_table

  # The public reservations board: the next fifty confirmed seatings.
  scope :on_board, lambda {
    confirmed.where(seating_at: Time.current..)
             .joins(:restaurant, :restaurant_table)
             .includes(:restaurant, :restaurant_table, :user)
             .order(:seating_at, Restaurant.arel_table[:name], RestaurantTable.arel_table[:label])
             .limit(50)
  }

  # A seating instant as every verb publishes it: ISO 8601 on the restaurant's clock.
  def self.publish_instant(time, zone = Seatings.default_zone)
    time&.in_time_zone(zone)&.iso8601
  end
end
