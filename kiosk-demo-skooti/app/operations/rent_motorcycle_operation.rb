# frozen_string_literal: true

# rent_motorcycle — start a rental of a COMBUSTION-ENGINE motorcycle.
#
# This is the KYC-ATTRIBUTE-GATED verb. Unlike the licence-free electric scooter
# (start_rental), a combustion motorcycle requires the calling agent to have
# completed a KYC attestation carrying BOTH named anonymized boolean attributes:
#
#     age_over_18 == true  AND  licence_a == true
#
# The provider learns only these two booleans — never the DOB or licence number
# (the anonymized/attestation privacy point).
#
# HONEST SCOPE (KYC-DEMO-SCOPE): this is an ELIGIBILITY gate — it proves a valid
# licence + 18+ *exist* behind the assistant — NOT an accountability mechanism.
# An anonymized claim is transferable (a licensed friend could vouch) and the
# demo settles a nameless hold, not a deposit, so nobody is on the hook for the
# actual rental. Real vehicle rental needs identity + a contract + insurance +
# a deposit on top (not modeled). This case illustrates the attestation
# MECHANISM; anonymized minimal KYC's clean home is a low-liability age-gated
# PURCHASE (see the getgrocery alcohol demo), where the transaction just closes.
#
# THE GATES, IN THIS ORDER — and Gate 0 coming FIRST is published behaviour, not
# an accident of writing: an un-attested agent is told to go and get attested
# even when its `reservation_id` is also missing or malformed, so the answer an
# assistant acts on is the one it can actually do something about.
#   0. KYC attributes: age_over_18 AND licence_a  → 403 kyc_required if unmet
#   1. the reservation exists, belongs to the principal, and is still reserved
#   2. the reserved vehicle IS a needs_licence motorcycle
#   3. a settled payment references THIS reservation
class RentMotorcycleOperation
  # The two anonymized booleans this verb demands. Named once, so the gate, the
  # refusal sentence and the hint cannot come to disagree about what is required.
  REQUIRED_KYC_ATTRIBUTES = %w[age_over_18 licence_a].freeze

  def self.call(reservation_id:)
    # ── Gate 0: the KYC named-attribute gate ───────────────────────────────
    # Reads what the ENGINE recorded for the acting agent — see
    # {Agent.kyc_granted?}, which keeps the `->>` extraction in Postgres for the
    # reason written there. Runs before the argument guards, unchanged.
    unless Agent.kyc_granted?(*REQUIRED_KYC_ATTRIBUTES)
      return OperationResult.refused(
        code:    "kyc_required",
        message: "motorcycle rental requires KYC attributes age_over_18 and licence_a",
        # Point an external agent at the completable path, in the spelling the
        # 0.4 wire actually uses: POST <endpoint>/request_kyc returns a
        # verification_url the human approves, then GET <endpoint>/kyc_status
        # carries the signed attestation, submitted to POST <endpoint>/agents/kyc
        # — no pre-shared issuer key needed (K-440/K-443).
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
    # THIS gate's direction: this verb is the one that unlocks a licence-required
    # vehicle, so only a value Rails casts to literal TRUE counts as one.
    # Anything ambiguous is refused here and refused there too, so no reading of
    # the column opens both doors (K-724).
    unless vehicle.licence_required?
      return OperationResult.refused(
        code:    "bad_request",
        message: "#{vehicle.code} is not a licence-required motorcycle — use start_rental " \
                 "for licence-free vehicles",
      )
    end

    # ── Gate 3: a settled payment referencing THIS reservation ─────────────
    refusal = RentalGates.unsettled(reservation_id)
    return refusal if refusal

    # ── All gates passed: issue the Ed25519 rental token ───────────────────
    RentalActivation.call(reservation: reservation, scooter: vehicle, reservation_id: reservation_id)
  end
end
