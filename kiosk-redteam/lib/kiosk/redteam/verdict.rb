# frozen_string_literal: true

module Kiosk
  module Redteam
    # BLOCKED: blocked. UNTESTED: the attack never reached the gate under test,
    # because a setup step or the environment failed. BREACH: none of these.
    # SKIPPED: the profile lacks the surface, which is not a pass. status is 0
    # for a skip.
    Verdict = Data.define(:blocked, :skipped, :status, :detail, :untested) do
      def initialize(untested: false, **) = super
    end
  end
end
