# frozen_string_literal: true

# Hands back the hotel's answer to a paid booking: the confirmation code it
# minted, or why there is none. Writes nothing. Returns the booking; raises a wire error on a refusal.
class ConfirmBookingOperation
  def self.call(booking_id:)
    booking = Booking.own.find_by(id: booking_id)
    refuse 'booking not found or not yours' unless booking
    refuse 'this hold lapsed unpaid and the room was released', hint: 'Search again for a room.' if booking.lapsed?
    refuse 'the hotel declined this booking and cancelled it', hint: cancellation_hint(booking) if booking.cancelled?
    refuse_until_answered(booking)

    booking
  end

  def self.cancellation_hint(booking)
    return 'Nothing was charged. Search again for another room.' unless booking.refund_psp_reference

    "The charge was refunded (#{booking.refund_psp_reference}) to the card that paid. Search again for another room."
  end

  def self.refuse_until_answered(booking)
    if booking.paying?
      refuse 'a payment for this booking is in progress — re-read my_bookings until payment_state is ' \
             '`paid`, and do not pay again'
    end
    refuse 'this booking is not paid yet', hint: 'Pay the total reserve_room quoted, then call again.' \
      unless booking.paid?
    return if booking.confirmed?

    refuse 'the hotel has not answered this booking yet',
           hint: 'Wait for the `booking_confirmation` event.'
  end

  def self.refuse(message, hint: nil)
    raise Kiosk::Server::Errors::Forbidden.new(message, hint: hint)
  end
end
