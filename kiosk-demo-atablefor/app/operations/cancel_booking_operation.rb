# frozen_string_literal: true

# Cancels one of the principal's own bookings, freeing its (table, seating).
class CancelBookingOperation
  def self.call(booking_id:)
    booking = Booking.own.confirmed.find_by(id: booking_id)
    # One answer for absent, foreign and already cancelled, so ids cannot be probed.
    raise Kiosk::Server::Errors::Forbidden, "booking not found, not yours, or already cancelled" unless booking

    booking.cancelled!
    { booking_id: booking_id, status: booking.status }
  end
end
