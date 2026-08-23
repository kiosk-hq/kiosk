# frozen_string_literal: true

# THE PRECONDITIONS BOTH RENTAL VERBS SHARE — ownership and payment — expressed
# once, as REFUSALS rather than as rendered responses. Nothing here writes, so
# it is not an Operation; the write both verbs share is {RentalActivation}.
#
# The vehicle-kind check is per-verb by nature (each refuses the other's), but
# ownership and payment are ONE question over one reservations table, and two
# copies of a security sentence is two chances to drift (K-687).
module RentalGates
  module_function

  # ── Ownership + state ──────────────────────────────────────────────────────
  # The reservation must belong to the principal the wire resolved AND still be
  # `reserved`. Owner-scoped by the GUC predicate, so a foreign uuid finds
  # nothing even with RLS inactive; the state half is what makes re-activating a
  # ride already in progress a refusal rather than a second unlock token.
  #
  # ONE answer for "no such reservation", "not yours" and "already active":
  # distinguishing them lets a caller enumerate other principals' ids. `find_by`,
  # not `find_by!` — the bang form's RecordNotFound renders as `not_found`, which
  # tells a prober the id is unknown.
  #
  # @return [Array(Reservation, nil), Array(nil, OperationResult)]
  def owned_reservation(reservation_id)
    reservation = Reservation.owned_by_current_principal
                             .still_reserved
                             .find_by(id: reservation_id)
    return [reservation, nil] if reservation

    [nil, OperationResult.refused(code: "forbidden", message: "reservation not found or not yours")]
  end

  # ── The vehicle the reservation is FOR ─────────────────────────────────────
  # Read server-side from the reservation's own FK, never from a client value:
  # this binds the rental token to the ACTUALLY reserved vehicle and closes the
  # cross-vehicle unlock. The two verbs word the miss differently, so the
  # sentence is the caller's to supply.
  #
  # @return [Array(Scooter, nil), Array(nil, OperationResult)]
  def vehicle_for(reservation, missing_message:)
    scooter = reservation.scooter
    return [scooter, nil] if scooter

    [nil, OperationResult.refused(code: "forbidden", message: missing_message)]
  end

  # ── Payment ────────────────────────────────────────────────────────────────
  # THIS PRINCIPAL has paid for THIS reservation — which is what stops paying
  # for reservation A and starting rental B.
  #
  # TWO WITNESSES, and the order matters (K-853). protocol.md §11.6 anchors paid
  # state to the CAPTURE, so skooti's own `payment_status`/`paid_by_user_id` pair
  # — written the instant the capture RETURNS — is consulted first: it is the
  # only witness that exists before the engine writes its settlement row, and a
  # gate reading the settlement alone would refuse a rental already charged.
  #
  # BOTH witnesses stay PRINCIPAL-SCOPED: the cashier deliberately lets B pay for
  # A's reservation (isolation flow), so "somebody paid" was never the question.
  # And `paid_by_user_id` is compared through Arel, NOT as a hash value:
  # `where(paid_by_user_id: Arel.sql("kiosk.current_user_id()"))` looks right and
  # is silently wrong — `Arel.sql` returns a String subclass, so ActiveRecord
  # binds the FUNCTION TEXT as a uuid value, casts it to NULL and matches no row.
  #
  # @return [OperationResult, nil] a refusal, or nil when the rental is paid for
  def payment_refusal(reservation_id)
    paid_here = Reservation.owned_by_current_principal
                           .where(id: reservation_id, payment_status: Reservation::PAID)
                           .where(Reservation.arel_table[:paid_by_user_id]
                                             .eq(Arel.sql("kiosk.current_user_id()")))
    settled = Settlement.of_current_principal
                        .joins(:cart_mandate)
                        .merge(CartMandate.referencing(reservation_id))
    return nil if paid_here.exists? || settled.exists?

    # A reservation with a capture OUTSTANDING is neither paid nor unpaid, and
    # §11.6 forbids saying "no settlement" about it: name the third state, so the
    # assistant waits and reconciles rather than signing a fresh chain.
    pending = Reservation.owned_by_current_principal
                         .where(id: reservation_id, payment_status: Reservation::PAYING)
    if pending.exists?
      return OperationResult.refused(
        code:    "forbidden",
        message: "a payment for this reservation is in progress and its outcome is not yet known — " \
                 "re-read my_reservations and start the rental once its payment_state is `paid`; do " \
                 "NOT sign a fresh mandate chain while it reads `pending`",
      )
    end

    OperationResult.refused(code: "forbidden", message: "no settlement for this reservation")
  end
end
