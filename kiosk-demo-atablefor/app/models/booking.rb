# frozen_string_literal: true

# One customer holding one table for one seating. Cancelling frees the
# (table, seating): the unique index `idx_bookings_confirmed_table_seating`
# covers confirmed rows only.
class Booking < ApplicationRecord
  include Kiosk::Owned

  MAX_PARTY_SIZE = 20

  enum :status, { confirmed: 'confirmed', cancelled: 'cancelled' }

  belongs_to :user
  belongs_to :restaurant
  belongs_to :restaurant_table

  before_validation(on: :create) { self.restaurant = restaurant_table&.restaurant }

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

  # Records the visit of a confirmed booking whose seating has passed, once:
  # the row lock makes two calls take turns, and the second finds it stamped.
  def self.honour!(booking_id)
    transaction do
      booking = confirmed.where(visit_recorded_at: nil, seating_at: ..Time.current).lock.find_by(id: booking_id)
      next unless booking

      booking.update!(visit_recorded_at: Time.current)
      Kiosk::Visit.record!(user_id: booking.user_id, value_cents: booking.restaurant.average_spend_cents * booking.party_size)
    end
  end

  # The seating on the restaurant's own clock.
  def local_seating = seating_at.in_time_zone(restaurant.zone)

  private

  def table_seats_party
    return if restaurant_table.nil? || party_size.nil? || restaurant_table.capacity >= party_size

    errors.add(:base, "#{restaurant_table.label} seats #{restaurant_table.capacity}; pick a larger table from availability")
  end

  def seating_upcoming
    return if restaurant.nil? || seating_at.nil?

    upcoming = restaurant.upcoming_seatings
    return if upcoming.include?(seating_at)

    errors.add(:seating_at, seating_refusal(upcoming))
  end

  def seating_refusal(upcoming)
    seating = wall_clock(local_seating)
    return "#{seating} has already started; pick an upcoming seating from availability" if seating_at.past?

    "#{seating} is not an upcoming seating; currently #{upcoming.map { wall_clock(it) }.join(', ').presence || 'none'}"
  end

  def wall_clock(seating) = seating.strftime('%Y-%m-%d %H:%M')
end
