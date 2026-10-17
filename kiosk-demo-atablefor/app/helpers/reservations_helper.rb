# frozen_string_literal: true

module ReservationsHelper
  def seating_label(booking) = Restaurant.seating_label(booking.local_seating)
end
