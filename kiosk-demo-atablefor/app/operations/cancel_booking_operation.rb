# frozen_string_literal: true

# cancel_booking — release one of the authenticated principal's own bookings,
# freeing the (table, seating) so it can be booked again. Owner-scoped: the
# WHERE gates on `user_id = kiosk.current_user_id()`, so a cross-principal
# cancel is a clean 403 — the booking is not found under the caller's identity.
class CancelBookingOperation
  def self.call(booking_id:)
    booking_id, refusal = WireArguments.booking_id(booking_id)
    return refusal if refusal

    # Owner-scoped, in ONE statement, so the ownership test and the write cannot
    # be separated by another transaction; the row count IS the answer.
    # `update_all` (not `update!`) is what keeps it one statement, and it skips
    # validations. The cancelled row leaves the confirmed set, so the unique
    # partial index frees the (table, seating) for a fresh booking.
    cancelled = Booking.owned_by_current_principal
                       .where(id: booking_id)
                       .where.not(status: Booking::CANCELLED)
                       .update_all(status: Booking::CANCELLED, updated_at: Time.current)

    if cancelled.zero?
      # ONE answer for "no such booking", "not yours" and "already cancelled":
      # distinguishing them would let a caller enumerate other principals' ids.
      return OperationResult.refused(
        code: "forbidden", message: "booking not found, not yours, or already cancelled",
      )
    end

    # Echoed VERBATIM as the caller sent it; never read back out of the database.
    OperationResult.ok({ booking_id: booking_id, status: "cancelled" })
  end
end
