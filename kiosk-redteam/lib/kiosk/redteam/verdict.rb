# frozen_string_literal: true

module Kiosk
  module Redteam
    # The result of running a single adversarial scenario.
    #
    # A Verdict is BLOCKED when the provider correctly rejected the attack.
    # A Verdict is NOT blocked when the attack was not rejected — this is a
    # genuine breach finding that must fail the redteam battery non-zero.
    #
    # Note: a 5xx or connection error is NEVER considered "blocked" — a crash
    # cannot masquerade as a successful enforcement.  Use INDETERMINATE handling
    # at the Scenario level and surface the detail string.
    #
    # @!attribute blocked [Boolean] true only when the attack was correctly blocked
    # @!attribute status  [Integer] HTTP status that drove the verdict
    # @!attribute detail  [String]  human-readable summary for the breach report line
    Verdict = Data.define(:blocked, :status, :detail)
  end
end
