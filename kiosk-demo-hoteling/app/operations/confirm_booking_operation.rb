# frozen_string_literal: true

# Hands back the property's answer to a paid booking: the confirmation code it
# minted, or why there is none. Writes nothing. Raises a wire error on a refusal.
class ConfirmBookingOperation
  def self.call(booking_id:)
    booking = Booking.own.find_by(id: booking_id)
    refuse "booking not found or not yours" unless booking

    if booking.cancelled?
      refuse "the property could not honour this booking and it was cancelled",
             hint: booking.refund_psp_reference ? "The charge was reversed (#{booking.refund_psp_reference}); " \
                                                  "the money is on its way back to the card that paid. " \
                                                  "Search again for another room." \
                                                : "Nothing was charged. Search again for another room."
    end
    if booking.paying?
      refuse "a payment for this booking is in progress and its outcome is not yet known — " \
             "re-read my_bookings and confirm once its payment_state is `paid`; do NOT sign a " \
             "fresh mandate chain while it reads `pending`"
    end
    refuse "no settlement for this booking" unless booking.paid?
    unless booking.confirmed?
      refuse "the property has not answered this booking yet",
             hint: "Subscribe to the `booking_confirmation` topic on this origin's event stream " \
                   "and wait; it carries the confirmation code, or the cancellation and the " \
                   "refund. Re-reading my_bookings shows the same answer once it arrives."
    end

    { booking_id: booking.id, status: "confirmed", confirmation_code: booking.confirmation_code }
  end

  def self.refuse(message, hint: nil)
    raise Kiosk::Server::Errors::Forbidden.new(message, hint: hint)
  end
end
