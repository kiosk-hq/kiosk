# frozen_string_literal: true

# confirm_booking — turn a paid-for hold into a confirmed stay and hand back the
# reference the guest gives at the desk.
#
# TWO GATES AND AN ANSWER, in that order. Gate 1 is OWNERSHIP (this booking,
# this principal) and Gate 2 is PAYMENT (a settlement whose cart references this
# booking). The isolation flow proves Gate 1 alone by having B genuinely satisfy
# Gate 2 for A's booking and still be refused.
#
# WHAT COMES AFTER THEM IS NOT A GATE — it is the property's answer, and this
# verb only reads it. A guest does not confirm their own booking; a hotel does.
# Paying is what starts it deciding, {PropertyDecisionJob} is the only thing
# that mints a confirmation code or cancels the booking, and this call hands
# back whatever it wrote.
class ConfirmBookingOperation
  def self.call(booking_id:)
    return WireArguments.missing("booking_id") if booking_id.blank?

    # A SHAPE check, not an access one. `where(id: junk)` does not
    # raise — ActiveRecord casts an unparseable uuid to NULL, which matches no
    # row — so without this a typo would be answered as an OWNERSHIP refusal
    # (403) instead of a 400. A well-formed but foreign id still gets the 403.
    unless Kiosk::UuidCheck.valid?(booking_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
                 "that reserve_room returned (also listed by my_bookings)",
      )
    end

    # Joins the request's SessionContext transaction; opens no second one.
    Booking.transaction do
      # ── Gate 1: the booking belongs to this principal ───────────────────────
      # Owner-scoped by the GUC predicate, so a cross-principal confirm finds
      # nothing. Deliberately ONE answer for "no such booking", "not yours" and
      # "already confirmed": distinguishing them would let a caller enumerate
      # other principals' booking ids. `exists?` and not `find_by!` — the bang
      # form's RecordNotFound renders as `not_found`, telling a prober the id is
      # unknown.
      mine = Booking.owned_by_current_principal.where(id: booking_id)
      row  = mine.pick(:status, :confirmation_code, :refund_psp_reference)
      unless row
        return OperationResult.refused(code: "forbidden", message: "booking not found or not yours")
      end
      status, code, refund_reference = row

      # ── Gate 2: THIS principal has paid for THIS booking ────────────────────
      # TWO WITNESSES, and the order matters. The engine's settlement row
      # is written in executor phase 3, AFTER the irreversible capture; the
      # `payment_status`/`paid_by_user_id` pair is hoteling's own, written the
      # instant the capture RETURNS. protocol.md §11.6 anchors paid state to the
      # CAPTURE, so the local marker is consulted first — it is the only witness
      # that exists in the window between the two.
      #
      # Both witnesses stay PRINCIPAL-SCOPED, which is what keeps this gate about
      # payment BY THE CALLER (the cashier deliberately lets B pay for A's
      # booking). `paid_by_user_id` is compared through an Arel NODE, never as a
      # hash value — `Arel.sql` returns a String subclass, so ActiveRecord would
      # bind the function TEXT as a uuid, cast it to NULL and match no row.
      paid_here = Booking.owned_by_current_principal
                         .where(id: booking_id, payment_status: Booking::PAID)
                         .where(Booking.arel_table[:paid_by_user_id]
                                       .eq(Arel.sql("kiosk.current_user_id()")))
      settled = Settlement.of_current_principal
                          .joins(:cart_mandate)
                          .merge(CartMandate.referencing(booking_id))
      unless paid_here.exists? || settled.exists?
        # A capture OUTSTANDING is neither paid nor unpaid, and §11.6 forbids
        # publishing it as "no settlement". Name the third state, so the
        # assistant waits and reconciles rather than re-minting a chain.
        pending = Booking.owned_by_current_principal
                         .where(id: booking_id, payment_status: Booking::PAYING)
        if pending.exists?
          return OperationResult.refused(
            code:    "forbidden",
            message: "a payment for this booking is in progress and its outcome is not yet known — " \
                     "re-read my_bookings and confirm once its payment_state is `paid`; do NOT sign a " \
                     "fresh mandate chain while it reads `pending`",
          )
        end

        return OperationResult.refused(code: "forbidden", message: "no settlement for this booking")
      end

      # ── THE PROPERTY'S ANSWER, read AFTER the payment gates ─────────────────
      #
      # The order is the point. An unpaid booking is `reserved` too, so putting
      # this first answered «the property has not answered yet» to a caller
      # whose real problem was that nothing had been charged — a true sentence
      # that sends an assistant to wait for an event that will never come. The
      # payment gates are more specific and they go first; only a caller who HAS
      # paid is waiting on the hotel.
      # ── THE PROPERTY HAS NOT ANSWERED YET ───────────────────────────────────
      # This verb no longer confirms anything: a guest does not confirm their
      # own booking, a hotel does. Paying starts the property deciding, and it
      # answers on its own clock — minutes, not milliseconds. So `reserved` here
      # is not a refusal about this caller at all; it is «not yet», and the
      # answer says where the answer will come from rather than inviting a poll
      # loop nobody specified.
      if status == Booking::RESERVED
        return OperationResult.refused(
          code:    "forbidden",
          message: "the property has not answered this booking yet",
          hint:    "Subscribe to the `booking_confirmation` topic on this origin's event stream " \
                   "and wait; it carries the confirmation code, or the cancellation and the " \
                   "refund. Re-reading my_bookings shows the same answer once it arrives.",
        )
      end

      # ── THE PROPERTY SAID NO ────────────────────────────────────────────────
      # The room-nights are free again and the money has gone back to the card
      # it came from. Naming the reversal here matters: an assistant telling its
      # human «that fell through» must be able to say what became of the money.
      if status == Booking::CANCELLED
        return OperationResult.refused(
          code:    "forbidden",
          message: "the property could not honour this booking and it was cancelled",
          hint:    refund_reference ? "The charge was reversed (#{refund_reference}); the money is " \
                                      "on its way back to the card that paid. Search again for " \
                                      "another room." \
                                    : "Nothing was charged. Search again for another room.",
        )
      end

      # ── The property confirmed: hand over what it wrote ─────────────────────
      # NOTHING IS WRITTEN HERE. The code was minted by {PropertyDecisionJob}
      # when the hotel accepted, so what the assistant is handed is provably
      # what the hotel stored rather than what this call happened to generate —
      # and calling twice cannot mint a second code, because this call mints
      # none.
      OperationResult.ok({
        booking_id:        booking_id,
        status:            Booking::CONFIRMED,
        confirmation_code: code,
      })
    end
  end
end
