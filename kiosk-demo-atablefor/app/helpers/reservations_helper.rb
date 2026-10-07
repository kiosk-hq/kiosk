# frozen_string_literal: true

module ReservationsHelper
  # A seating on the restaurant's own clock, the clock named beside it — the
  # sentence the wire publishes as `seating_label`.
  def seating_label(booking)
    zone  = booking.restaurant.zone
    local = booking.seating_at.in_time_zone(zone)
    "#{local.strftime('%a %d %b')} · #{Seatings.label(local.strftime('%H:%M'), zone)}"
  end
end
