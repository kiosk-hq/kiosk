# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # With a PoW gate, registration with no proof or a wrong one must be refused
      # (not a 201, no token, not a crash), while a solved control registration succeeds.
      class RegistrationWithoutPow < Scenario
        def initialize
          super(name: 'RegistrationWithoutPow')
        end

        def call(client, profile)
          return skip_verdict('pow_difficulty is 0 (no PoW gate)') unless profile.pow_difficulty.positive?

          attack(client)
        end

        private

        def attack(client)
          attempts = [['pow: :skip', client.register_raw(pow: :skip)], ['pow: "0"', client.register_raw(pow: '0')]]
          problems = attempts.filter_map { |label, resp| not_a_pow_rejection(label, resp) }
          control = control_registration(client, problems)

          Verdict.new(blocked: problems.empty?, skipped: false,
                      status: (control || attempts.last.last).status, detail: problems.join('; '))
        end

        # The control costs a real solve, so it runs only when both attempts were refused.
        # A failed control appends its problem.
        def control_registration(client, problems)
          return nil unless problems.empty?

          control = client.register_raw
          problems << control_problem(control) unless honest_registration?(control)
          control
        end

        def honest_registration?(control)
          control.status == 201 && token_of(control)
        end

        def control_problem(control)
          'CONTROL FAILED: a properly solved registration must return 201 with ' \
            "an access_token — got HTTP #{control.status} #{control.body.inspect}. " \
            'A server that refuses every registration refuses the two unproven ' \
            'ones too, which says nothing about a PoW gate.'
        end

        # Why this attempt is not a PoW refusal, or nil when it is.
        def not_a_pow_rejection(label, resp)
          return "#{label} returned 201 — registration succeeded with no proof" if resp.status == 201
          if resp.status >= 500 || resp.status.zero?
            return "#{label} crashed (HTTP #{resp.status}: #{resp.body.inspect}) — " \
                   'a crash is not a gate'
          end
          return nil unless token_of(resp)

          "#{label} returned an access_token on HTTP #{resp.status}"
        end

        def token_of(resp)
          body = resp.body
          body.is_a?(Hash) ? body['access_token'] : nil
        end
      end
    end
  end
end
