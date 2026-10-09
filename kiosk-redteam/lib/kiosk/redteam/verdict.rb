# frozen_string_literal: true

module Kiosk
  module Redteam
    # BLOCKED: blocked. BREACH: neither blocked nor skipped. SKIPPED: the profile
    # lacks the surface, which is not a pass. status is 0 for a skip.
    Verdict = Data.define(:blocked, :skipped, :status, :detail)
  end
end
