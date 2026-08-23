# frozen_string_literal: true

# confirm_booking — turn a paid-for hold into a confirmed stay and hand back the
# reference the guest gives at the desk.
#
# TWO GATES, and they are separable on purpose: Gate 1 is OWNERSHIP (this
# booking, this principal, still reserved) and Gate 2 is PAYMENT (a settlement
# whose cart references this booking). The isolation flow proves Gate 1 alone by
# having B genuinely satisfy Gate 2 for A's booking and still be refused.
class ConfirmBookingOperation
  def self.call(booking_id:)
    return WireArguments.missing("booking_id") if booking_id.blank?

    # K-581/K-582: a SHAPE check, not an access one. `where(id: junk)` does not
    # raise — ActiveRecord casts an unparseable uuid to NULL, which matches no
    # row — so without this a typo would be answered as an OWNERSHIP refusal
    # (403) instead of a 400. A well-formed but foreign id still gets the 403.
    unless UuidCheck.valid?(booking_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "booking_id #{booking_id.to_s.inspect} is not a uuid — pass the `booking_id` " \
                 "that reserve_room returned (also listed by my_bookings)",
      )
    end

    # Joins the request's SessionContext transaction; opens no second one.
    Booking.transaction do
      # ── Gate 1: booking belongs to principal AND status = 'reserved' ────────
      # Owner-scoped by the GUC predicate, so a cross-principal confirm finds
      # nothing. Deliberately ONE answer for "no such booking", "not yours" and
      # "already confirmed": distinguishing them would let a caller enumerate
      # other principals' booking ids. `exists?` and not `find_by!` — the bang
      # form's RecordNotFound renders as `not_found`, telling a prober the id is
      # unknown.
      mine = Booking.owned_by_current_principal.where(id: booking_id, status: Booking::RESERVED)
      unless mine.exists?
        return OperationResult.refused(code: "forbidden", message: "booking not found or not yours")
      end

      # ── Gate 2: THIS principal has paid for THIS booking ────────────────────
      # TWO WITNESSES, and the order matters (K-853). The engine's settlement row
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

      # ── All gates passed: confirm ───────────────────────────────────────────
      # K-698: the code is PERSISTED by this UPDATE and read back OUT of the row,
      # so what the assistant is handed is provably what the hotel stored. The
      # COALESCE keeps an already-coded booking's code stable. The read-back is a
      # second statement because Rails 8.1's `update_all` has no `returning:`.
      code = SecureRandom.uuid
      mine.update_all(
        status:            Booking::CONFIRMED,
        confirmation_code: Arel::Nodes::NamedFunction.new(
          "COALESCE", [Booking.arel_table[:confirmation_code], Arel::Nodes.build_quoted(code)],
        ),
        updated_at:        Time.current,
      )

      OperationResult.ok({
        booking_id:        booking_id,
        status:            "confirmed",
        confirmation_code: Booking.owned_by_current_principal.where(id: booking_id).pick(:confirmation_code),
      })
    end
  end
end
