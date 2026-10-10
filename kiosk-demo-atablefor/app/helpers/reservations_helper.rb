# frozen_string_literal: true

module ReservationsHelper
  # A seating on the restaurant's own clock, the clock named beside it — the
  # sentence the wire publishes as `seating_label`.
  def seating_label(booking)
    seating = booking.local_seating
    "#{seating.strftime('%a %d %b')} · #{Restaurant.seating_label(seating)}"
  end
end
