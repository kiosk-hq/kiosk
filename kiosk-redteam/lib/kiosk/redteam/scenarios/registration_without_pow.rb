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
      #   3. BLOCKED iff BOTH are rejected (non-201, no access_token returned).
      #
      # Skipped when: profile.pow_difficulty == 0 (provider has no PoW gate).
      #
      # Note: this scenario does NOT delegate to Kiosk::Redteam.blocked? because
      # a 400 "bad_request" validation error is not evidence of a PoW gate — only
      # the absence of a successful registration (HTTP 201 + access_token) is.
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

          skip_blocked = registration_rejected?(resp_skip)
          zero_blocked = registration_rejected?(resp_zero)

          if skip_blocked && zero_blocked
            Verdict.new(blocked: true, skipped: false, status: resp_zero.status, detail: "")
          else
            details = []
            details << "pow: :skip returned #{resp_skip.status}" unless skip_blocked
            details << "pow: \"0\" returned #{resp_zero.status}" unless zero_blocked
            Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp_zero.status,
              detail:  details.join("; "),
            )
          end
        end

        private

        # A PoW-required registration is blocked when the response is NOT a
        # successful 201 with an access_token.  Any non-201 response without
        # a token means the server rejected the attempt.
        def registration_rejected?(resp)
          return false if resp.status == 201

          body = resp.body
          return true unless body.is_a?(Hash)

          body["access_token"].nil?
        end
      end
    end
  end
end
