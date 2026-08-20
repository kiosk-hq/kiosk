# frozen_string_literal: true

# start_rental — verify the gates, then issue an Ed25519 rental token for a
# LICENCE-FREE vehicle's lock.
#
# `scooter_code` is not accepted from the client at all: it is derived
# server-side from the reservation row, which is what prevents a cross-vehicle
# unlock.
#
# THE GATES, IN THIS ORDER, and the order is behaviour rather than tidiness —
# each one is the answer a caller gets when a later one would also have refused:
#   1.  the reservation exists, belongs to the principal, and is still reserved
#   1b. the reserved vehicle is licence-FREE — a needs_licence motorcycle is
#       refused here and sent to rent_motorcycle (K-687)
#   2.  the principal has a settled payment for THIS reservation
#
# Licence-free scooters need NO KYC (K-442, DECISIONS-LOG KYC-MODEL) — "ride
# even if you can't walk yet, just pay the fare". That is a statement about
# SCOOTERS, and gate 1b is what makes it one: the combustion motorcycle is
# KYC-gated on rent_motorcycle, and before K-687 this verb would happily
# activate a motorcycle reservation and hand back an unlock token, so the
# licence gate was one verb name away from being optional.
#
# No `transaction` block: the whole call already runs inside the ONE
# SessionContext transaction the wire opened (that is where the GUCs the
# ownership predicate reads are SET LOCAL), so a second one would only be a
# join, and the reads-then-one-UPDATE sequence is atomic for exactly the reason
# it was before the conversion.
class StartRentalOperation
  # The principal is NOT passed in: gate 1 expresses it as a WHERE predicate
  # over `kiosk.current_user_id()`, which is un-forgeable without naming it in
  # Ruby at all.
  def self.call(reservation_id:)
    reservation_id, refusal = WireArguments.reservation_id(reservation_id)
    return refusal if refusal

    # ── Gate 1: ownership + state ──────────────────────────────────────────
    reservation, refusal = RentalGates.owned_reservation(reservation_id)
    return refusal if refusal

    # The authoritative vehicle, from the reservation's own FK. `needs_licence`
    # comes with it — see the vehicle-kind gate below.
    scooter, refusal = RentalGates.vehicle_for(reservation, missing_message: "scooter not found for reservation")
    return refusal if refusal

    # ── Gate 1b: the reserved vehicle must be licence-FREE (K-687) ─────────
    # The exact inverse of rent_motorcycle's Gate 2, and the reason it must
    # exist: the two verbs share one reservations table, so without this check
    # an agent reserves the KYC-gated motorcycle and activates it with the
    # licence-free verb — reserve(MC-001) → pay → start_rental returned a signed
    # unlock token to an agent that had never attested anything, bypassing the
    # age_over_18 + licence_a gate entirely. It went unseen because every driver
    # called start_rental with SK-001. `reserve` deliberately stays open to
    # every vehicle (one reservation shape, both verbs); the licence check
    # belongs at USE time, here, next to the ownership and payment gates.
    #
    # {Scooter#licence_free?} is where the fail-closed coercion lives, and it is
    # the SAME predicate rent_motorcycle reads in the other direction, so no
    # reading of the column can open both doors (K-724).
    #
    # It fires BEFORE the payment gate, deliberately and unchanged: an agent
    # that reserved the wrong vehicle is told to change VERB, not told to pay
    # first and refused afterwards.
    unless scooter.licence_free?
      return OperationResult.refused(
        code:    "bad_request",
        message: "#{scooter.code} is a licence-required motorcycle — use rent_motorcycle " \
                 "for licence-required vehicles",
        # Point at the completable path, as the KYC gate's own hint does: the
        # right verb, and the KYC it will demand, so an assistant does not
        # simply retry this one.
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
