# frozen_string_literal: true

# start_rental — verify the gates, then issue an Ed25519 rental token for a
# LICENCE-FREE vehicle's lock.
#
# `scooter_code` is not accepted from the client at all: it is derived
# server-side from the reservation row, which prevents a cross-vehicle unlock.
#
# THE GATES, IN THIS ORDER, and the order is behaviour rather than tidiness —
# each one is the answer a caller gets when a later one would also have refused:
#   1.  the reservation exists, belongs to the principal, and is still reserved
#   1b. the reserved vehicle is licence-FREE — a needs_licence motorcycle is
#       refused here and sent to rent_motorcycle (K-687)
#   2.  the principal has a settled payment for THIS reservation
#
# Licence-free scooters need NO KYC (K-442, decided 2026-08-04) — "ride
# even if you can't walk yet, just pay the fare". Gate 1b is what keeps that a
# statement about SCOOTERS.
#
# No `transaction` block: the call already runs inside the ONE SessionContext
# transaction the wire opened — that is where the GUCs the ownership predicate
# reads are SET LOCAL — so a second one would only be a join.
class StartRentalOperation
  # The principal is NOT passed in: gate 1 expresses it as a WHERE predicate over
  # `kiosk.current_user_id()`, un-forgeable without naming it in Ruby at all.
  def self.call(reservation_id:)
    reservation_id, refusal = WireArguments.reservation_id(reservation_id)
    return refusal if refusal

    # ── Gate 1: ownership + state ──────────────────────────────────────────
    reservation, refusal = RentalGates.owned_reservation(reservation_id)
    return refusal if refusal

    # The authoritative vehicle, from the reservation's own FK.
    scooter, refusal = RentalGates.vehicle_for(reservation, missing_message: "scooter not found for reservation")
    return refusal if refusal

    # ── Gate 1b: the reserved vehicle must be licence-FREE (K-687) ─────────
    # The exact inverse of rent_motorcycle's Gate 2, and the reason it must
    # exist: the two verbs share one reservations table, so without it an agent
    # reserves the KYC-gated motorcycle and activates it with the licence-free
    # verb, bypassing the age_over_18 + licence_a gate. {Scooter#licence_free?}
    # is the fail-closed coercion, the SAME predicate rent_motorcycle reads in
    # the other direction, so no reading of the column opens both doors (K-724).
    #
    # It fires BEFORE the payment gate: an agent that reserved the wrong vehicle
    # is told to change VERB, not told to pay first and refused afterwards.
    unless scooter.licence_free?
      return OperationResult.refused(
        code:    "bad_request",
        message: "#{scooter.code} is a licence-required motorcycle — use rent_motorcycle " \
                 "for licence-required vehicles",
        hint:    "POST <endpoint>/rent_motorcycle with this reservation_id instead; it requires " \
                 "the KYC attributes age_over_18 and licence_a — if you do not have them yet, " \
                 "POST <endpoint>/request_kyc first",
      )
    end

    # ── Gate 2: THIS principal has PAID for THIS reservation ───────────────
    # Capture-anchored, not settlement-anchored (K-853) — see RentalGates.
    refusal = RentalGates.payment_refusal(reservation_id)
    return refusal if refusal

    # ── All gates passed: issue the Ed25519 rental token ───────────────────
    RentalActivation.call(reservation: reservation, scooter: scooter, reservation_id: reservation_id)
  end
end
