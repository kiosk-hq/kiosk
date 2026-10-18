# frozen_string_literal: true

module Kiosk
  module Redteam
    # Runs scenarios, prints a BLOCKED / SKIP / UNTESTED / BREACH line for each and returns
    # the `{ scenario:, verdict: }` results; `Battery#absorb` scores them.
    class Runner
      def initialize(base_url:, profile:)
        @client  = Kiosk::TestHelpers::Assistant.new(base_url:)
        @profile = profile
      end

      def run(scenarios)
        scenarios.map do |scenario|
          verdict = scenario.call(@client, @profile)
          print_line(scenario, verdict)
          { scenario:, verdict: }
        end
      end

      private

      def print_line(scenario, verdict)
        if verdict.skipped
          puts "  SKIP    — #{scenario.name} (#{verdict.detail.delete_prefix('SKIP — ')})"
        elsif verdict.blocked
          # The status says which gate answered.
          puts "  BLOCKED ✓ #{scenario.name} (HTTP #{verdict.status})"
        elsif verdict.untested
          puts "  UNTESTED ! #{scenario.name} — #{verdict.detail}"
        else
          puts "  BREACH  ✗ #{scenario.name} — #{verdict.detail}"
        end
      end
    end
  end
end
