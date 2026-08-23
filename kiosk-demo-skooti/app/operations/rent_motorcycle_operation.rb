# frozen_string_literal: true

# rent_motorcycle — start a rental of a COMBUSTION-ENGINE motorcycle, the
# KYC-ATTRIBUTE-GATED verb. Unlike the licence-free scooter (start_rental) it
# requires the calling agent to hold a KYC attestation carrying BOTH anonymized
# booleans — `age_over_18` and `licence_a`. The provider learns only those two,
# never the DOB or the licence number.
#
# HONEST SCOPE (KYC-DEMO-SCOPE): an ELIGIBILITY gate, not an accountability one
# — an anonymized claim is transferable and the demo settles a nameless hold, so
# real rental still needs identity, a contract, insurance and a deposit.
#
# THE GATES, IN THIS ORDER — Gate 0 first is published behaviour: an un-attested
# agent is told to get attested even when its `reservation_id` is also missing.
#   0. KYC attributes: age_over_18 AND licence_a  → 403 kyc_required if unmet
#   1. the reservation exists, belongs to the principal, and is still reserved
#   2. the reserved vehicle IS a needs_licence motorcycle
#   3. a settled payment references THIS reservation
class RentMotorcycleOperation
  # Named once, so the gate, the refusal and the hint cannot disagree.
  REQUIRED_KYC_ATTRIBUTES = %w[age_over_18 licence_a].freeze

  def self.call(reservation_id:)
    # ── Gate 0: the KYC named-attribute gate ───────────────────────────────
    # What the ENGINE recorded for the acting agent, before the argument guards.
    unless Agent.kyc_granted?(*REQUIRED_KYC_ATTRIBUTES)
      return OperationResult.refused(
        code:    "kyc_required",
        message: "motorcycle rental requires KYC attributes age_over_18 and licence_a",
        # The completable path: no pre-shared issuer key needed (K-440/K-443).
        hint:    "POST <endpoint>/request_kyc to start age≥18 + category-A licence verification: " \
                 "it returns a verification_url for the human to approve; then poll " \
                 "GET <endpoint>/kyc_status for the signed attestation and submit it to " \
                 "POST <endpoint>/agents/kyc, then retry rent_motorcycle",
      )
    end

    reservation_id, refusal = WireArguments.reservation_id(reservation_id)
    return refusal if refusal

    # ── Gate 1: ownership + state ──────────────────────────────────────────
    reservation, refusal = RentalGates.owned_reservation(reservation_id)
    return refusal if refusal

    vehicle, refusal = RentalGates.vehicle_for(reservation, missing_message: "vehicle not found for reservation")
    return refusal if refusal

    # ── Gate 2: the reserved vehicle IS a needs_licence motorcycle ─────────
    # {Scooter#licence_required?} is start_rental's Gate 1b predicate closed in
    # THIS direction: only a value Rails casts to literal TRUE unlocks one, so an
    # ambiguous column reading opens neither door rather than both (K-724).
    unless vehicle.licence_required?
      return OperationResult.refused(
        code:    "bad_request",
        message: "#{vehicle.code} is not a licence-required motorcycle — use start_rental " \
                 "for licence-free vehicles",
      )
    end

    # ── Gate 3: THIS principal has PAID for THIS reservation ───────────────
    # Capture-anchored, not settlement-anchored (K-853) — see RentalGates.
    refusal = RentalGates.payment_refusal(reservation_id)
    return refusal if refusal

    # ── All gates passed: issue the Ed25519 rental token ───────────────────
    RentalActivation.call(reservation: reservation, scooter: vehicle, reservation_id: reservation_id)
  end
end
