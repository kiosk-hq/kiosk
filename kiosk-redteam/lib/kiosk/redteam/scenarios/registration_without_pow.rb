# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # With a PoW gate, registration with no proof or a wrong one must be refused
      # (not a 201, no token, not a crash), while a solved control registration succeeds.
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

          resp_skip = client.register_raw(pow: :skip)

          resp_zero = client.register_raw(pow: "0")

          problems = [
            not_a_pow_rejection("pow: :skip", resp_skip),
            not_a_pow_rejection("pow: \"0\"", resp_zero),
          ].compact

          # The control costs a real solve, so it runs only when both attempts were refused.
          control = nil
          if problems.empty?
            control = client.register_raw
            unless control.status == 201 && token_of(control)
              problems << "CONTROL FAILED: a properly solved registration must return 201 with " \
                          "an access_token — got HTTP #{control.status} #{control.body.inspect}. " \
                          "A server that refuses every registration refuses the two unproven " \
                          "ones too, which says nothing about a PoW gate."
            end
          end

          Verdict.new(
            blocked: problems.empty?,
            skipped: false,
            status:  control ? control.status : resp_zero.status,
            detail:  problems.join("; "),
          )
        end

        private

        # Why this attempt is not a PoW refusal, or nil when it is.
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
