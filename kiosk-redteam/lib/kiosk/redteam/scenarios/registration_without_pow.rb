# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Registration spam without PoW: when PoW is required, a missing or
      # invalid proof must be rejected.
      #
      # Attack:
      #   1. Attempt register_raw with pow: :skip  (omit the pow field entirely).
      #   2. Attempt register_raw with pow: "0"    (trivially wrong proof).
      #   3. BLOCKED iff BOTH are rejected (non-201 and blocked status).
      #
      # Skipped when: profile.pow_difficulty == 0 (provider has no PoW gate).
      class RegistrationWithoutPow < Scenario
        def initialize
          super(
            name:        "RegistrationWithoutPow",
            category:    "registration",
            description: "Missing / bad PoW must be rejected when pow_difficulty > 0",
          )
        end

        def call(client, profile)
          return skip_verdict("pow_difficulty is 0 (no PoW gate)") unless profile.pow_difficulty > 0

          resp_skip = client.register_raw(
            name:           "redteam-rpow-skip",
            pow_difficulty: profile.pow_difficulty,
            pow:            :skip,
          )

          resp_zero = client.register_raw(
            name:           "redteam-rpow-zero",
            pow_difficulty: profile.pow_difficulty,
            pow:            "0",
          )

          both_blocked = Kiosk::Redteam.blocked?(resp_skip) && Kiosk::Redteam.blocked?(resp_zero)

          if both_blocked
            Verdict.new(blocked: true, status: resp_zero.status, detail: "")
          else
            details = []
            details << "pow: :skip returned #{resp_skip.status}"  unless Kiosk::Redteam.blocked?(resp_skip)
            details << "pow: \"0\" returned #{resp_zero.status}"  unless Kiosk::Redteam.blocked?(resp_zero)
            Verdict.new(
              blocked: false,
              status:  resp_zero.status,
              detail:  details.join("; "),
            )
          end
        end
      end
    end
  end
end
