# frozen_string_literal: true

# One principal holding one table for one seating. Cancelling frees the
# (table, seating): the unique index `idx_bookings_confirmed_table_seating`
# covers confirmed rows only.
class Booking < ApplicationRecord
  include Kiosk::Owned

  MAX_PARTY_SIZE = 20

  enum :status, { confirmed: "confirmed", cancelled: "cancelled" }

  belongs_to :user
  belongs_to :restaurant
  belongs_to :restaurant_table

  validates :party_size, numericality: { only_integer: true, in: 1..MAX_PARTY_SIZE }
  validate :table_seats_party, :seating_upcoming, on: :create

  # The public reservations board: the next fifty confirmed seatings.
  scope :on_board, lambda {
    confirmed.where(seating_at: Time.current..)
             .joins(:restaurant, :restaurant_table)
             .includes(:restaurant, :restaurant_table, :user)
             .order(:seating_at, Restaurant.arel_table[:name], RestaurantTable.arel_table[:label])
             .limit(50)
  }

  # The seating on the restaurant's own clock.
  def local_seating = seating_at.in_time_zone(restaurant.zone)

  private

  def table_seats_party
    return if restaurant_table.nil? || party_size.nil?
    return if restaurant_table.restaurant_id == restaurant_id && restaurant_table.capacity >= party_size

    errors.add(:restaurant_table, "#{restaurant_table_id} at restaurant #{restaurant_id} does not seat #{party_size}")
  end

  def seating_upcoming
    return if restaurant.nil? || seating_at.nil?

    upcoming = restaurant.upcoming_seatings
    return if upcoming.include?(seating_at)

    if seating_at.past?
      errors.add(:seating_at, "#{wall_clock(local_seating)} has already started — call availability again " \
                              "for the still-bookable seatings")
    else
      errors.add(:seating_at, "#{wall_clock(local_seating)} is not among the upcoming seatings — currently " \
                              "#{upcoming.map { wall_clock(_1) }.join(", ").presence || "none"}")
    end
  end

  def wall_clock(seating) = seating.strftime("%Y-%m-%d %H:%M")
end
