# frozen_string_literal: true

# cancel_booking — release one of the authenticated principal's own bookings,
# freeing the (table, seating) so it can be booked again.
class CancelBookingOperation
  # Owner-scoped: the WHERE gates on `user_id = kiosk.current_user_id()`, so a
  # cross-principal cancel on another's booking is a clean 403 — the booking is
  # not found under the caller's identity.
  def self.call(booking_id:)
    booking_id, refusal = WireArguments.booking_id(booking_id)
    return refusal if refusal

    # Owner-scoped, in ONE statement. It was two — a SELECT that decided the 403
    # and an UPDATE that did the work — and collapsing them is not just tidier:
    # the ownership test and the write can no longer be separated by another
    # transaction. `update_all` (not `update!`) keeps that single-statement
    # property and skips validations exactly as the previous UPDATE did; the row
    # count IS the answer. Cancelling drops the row out of the confirmed set, so
    # the unique partial index frees the (table, seating) for a fresh booking.
    cancelled = Booking.owned_by_current_principal
                       .where(id: booking_id)
                       .where.not(status: Booking::CANCELLED)
                       .update_all(status: Booking::CANCELLED, updated_at: Time.current)

    if cancelled.zero?
      # Owner-scoped miss. Deliberately ONE answer for "no such booking", "not
      # yours" and "already cancelled": distinguishing them would let a caller
      # enumerate other principals' booking ids.
      return OperationResult.refused(
        code: "forbidden", message: "booking not found, not yours, or already cancelled",
      )
    end

    # The id is echoed back VERBATIM as the caller sent it, which is what the
    # handler did — it never read the id back out of the database.
    OperationResult.ok({ booking_id: booking_id, status: "cancelled" })
  end
end
