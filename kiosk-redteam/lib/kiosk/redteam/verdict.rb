# frozen_string_literal: true

module Kiosk
  module Redteam
    # The result of running a single adversarial scenario.
    #
    # Three states:
    #   BLOCKED  — blocked: true,  skipped: false — attack correctly rejected.
    #   BREACH   — blocked: false, skipped: false — attack NOT rejected (real finding).
    #   SKIPPED  — skipped: true                  — profile lacks the surface;
    #              scenario was not exercised; does NOT count as a pass.
    #
    # Note: a 5xx or connection error is NEVER considered "blocked" — a crash
    # cannot masquerade as a successful enforcement.  There is no fourth state
    # to route it to: it comes back as the BREACH row above, and what tells a
    # real finding apart from an answer that proved nothing is the `detail`
    # string — {Scenario#verdict_from} names what was demanded and what came
    # back, {Scenario#payment_required_stall} opens with "COULD NOT TEST".
    #
    # @!attribute blocked [Boolean] true only when the attack was correctly blocked
    # @!attribute skipped [Boolean] true when the profile lacks the needed surface
    # @!attribute status  [Integer] HTTP status that drove the verdict (0 for skips)
    # @!attribute detail  [String]  human-readable summary for the breach/skip line
    Verdict = Data.define(:blocked, :skipped, :status, :detail)
  end
end
