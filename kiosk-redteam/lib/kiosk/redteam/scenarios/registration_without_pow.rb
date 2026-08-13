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
      #   3. CONTROL — register_raw with pow: :solve must return 201 + a token.
      #   4. BLOCKED iff BOTH attempts are rejected (non-201, no access_token,
      #      not a crash) AND the control registration succeeds.
      #
      # Skipped when: profile.pow_difficulty == 0 (provider has no PoW gate).
      #
      # Note: this scenario does NOT delegate to Kiosk::Redteam.blocked? because
      # a 400 "bad_request" validation error is not evidence of a PoW gate — only
      # the absence of a successful registration (HTTP 201 + access_token) is.
      #
      # The control is what makes "both were rejected" mean anything (K-730).
      # A server that rejects EVERY registration satisfies both attack legs
      # without owning a PoW gate at all: this scenario was demonstrated
      # printing BLOCKED against a server that answered 404 on every path.
      # A 5xx is likewise not a rejection — an unhandled exception in the
      # register path refuses the attempt by accident, and would go on refusing
      # it after the PoW check was deleted.
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

          problems = [
            not_a_pow_rejection("pow: :skip", resp_skip),
            not_a_pow_rejection("pow: \"0\"", resp_zero),
          ].compact

          # Only when both attempts were refused does the control matter: an
          # attempt that SUCCEEDED is already conclusive, and the control costs
          # a real Equihash solve.
          control = nil
          if problems.empty?
            control = client.register_raw(
              name:           "redteam-rpow-control",
              pow_difficulty: profile.pow_difficulty,
              pow:            :solve,
            )
            unless control.status == 201 && token_of(control)
              problems << "CONTROL FAILED: a properly solved registration must return 201 with " \
                          "an access_token — got HTTP #{control.status} #{control.body.inspect}. " \
                          "A server that refuses every registration refuses the two unproven " \
                          "ones too, which says nothing about a PoW gate."
            end
          end

          # When the control ran it is the decisive response — 201 on a pass,
          # and on a failure the status that explains why nothing was proved.
          Verdict.new(
            blocked: problems.empty?,
            skipped: false,
            status:  control ? control.status : resp_zero.status,
            detail:  problems.join("; "),
          )
        end

        private

        # Why this attempt does NOT count as a PoW rejection, or nil when it
        # does.  Rejection means: not a 201, no access_token handed back, and
        # not a crash — a 5xx refuses the registration by accident and would
        # keep refusing it with the PoW check deleted.
        def not_a_pow_rejection(label, resp)
          return "#{label} returned 201 — registration succeeded with no proof" if resp.status == 201
          if resp.status >= 500 || resp.status.zero?
            return "#{label} crashed (HTTP #{resp.status}: #{resp.body.inspect}) — " \
                   "a crash is not a gate"
          end
          return nil unless token_of(resp)

          "#{label} returned an access_token on HTTP #{resp.status}"
        end

        def token_of(resp)
          body = resp.body
          body.is_a?(Hash) ? body["access_token"] : nil
        end
      end
    end
  end
end
