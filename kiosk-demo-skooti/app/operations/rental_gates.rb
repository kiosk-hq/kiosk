# frozen_string_literal: true

# THE PRECONDITIONS BOTH RENTAL VERBS SHARE — ownership and payment — expressed
# once, as REFUSALS rather than as rendered responses ({ListAccess}'s shape).
#
# WHY THEY ARE SHARED AT ALL, and why sharing them is the point rather than a
# tidying. `start_rental` and `rent_motorcycle` are two verbs over ONE
# reservations table. K-687 is exactly what that costs when the two disagree:
# the licence gate lived on one verb, so reserve(MC-001) → pay → start_rental
# handed an unlock token to an agent that had attested nothing, and it went
# unseen because every driver called start_rental with SK-001. The vehicle-kind
# check is per-verb by nature (each refuses the other's vehicle), but ownership
# and payment are the SAME question asked twice, with the same answer sentence —
# and two copies of a security sentence is two chances for one of them to drift.
#
# NOT an Operation: nothing here writes. The write both verbs share is
# {RentalActivation}.
module RentalGates
  module_function

  # ── Ownership + state ──────────────────────────────────────────────────────
  # The reservation must belong to the principal the wire resolved AND still be
  # `reserved`. Owner-scoped by the GUC predicate, so a foreign reservation uuid
  # finds nothing even with RLS inactive; the state half is what makes a
  # re-activation of a ride already in progress a refusal rather than a second
  # unlock token (the C3 SpentResourceReuse beat).
  #
  # Deliberately ONE answer for "no such reservation", "not yours" and "already
  # active": distinguishing them would let a caller enumerate other principals'
  # reservation ids. `find_by`, not `find_by!` — the bang form raises
  # RecordNotFound, which Rails maps to 404 and the mixin's `rescue_from` floor
  # would render as `not_found`, telling a prober that the id is unknown. That
  # is the tudu reasoning and it applies verbatim.
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
  # this is what binds the rental token to the ACTUALLY reserved vehicle and
  # closes the cross-vehicle unlock. The two verbs word the miss differently
  # ("scooter" vs "vehicle"), so the sentence is the caller's to supply.
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
  # TWO WITNESSES, and the order matters (K-853). The settlement row is the
  # engine's, written in executor phase 3 — AFTER the irreversible capture. The
  # `payment_status`/`paid_by_user_id` pair is skooti's own, written by the
  # cashier the instant the capture RETURNS. protocol.md §11.6 anchors paid
  # state to the CAPTURE, so the local marker is consulted first: it is the only
  # witness that exists during the window between the two, and a gate that read
  # the settlement alone would refuse a rental whose money has already moved —
  # the refusal that sends an assistant back to sign a fresh chain.
  #
  # BOTH witnesses stay PRINCIPAL-SCOPED, which is what keeps this gate about
  # payment BY THE CALLER rather than payment by anyone: the settlement arm
  # through `of_current_principal`, the local arm through `paid_by_user_id`.
  # skooti's cashier deliberately lets B pay for A's reservation (isolation
  # flow), so "somebody paid" was never the question this gate asks.
  #
  # `paid_by_user_id` is compared through Arel and NOT as a hash value:
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
    # saying "no settlement" about it is what §11.6 forbids. Name the third state
    # instead, so the assistant waits and reconciles rather than re-minting.
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
