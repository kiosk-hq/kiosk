# frozen_string_literal: true

module Kiosk
  module Redteam
    # Runs scenarios and prints a BLOCKED / SKIP / BREACH line for each.
    # Gate on `exit 1 unless runner.all_blocked?`: `breaches` is empty when nothing ran.
    class Runner
      def initialize(base_url:, profile:)
        @client  = Kiosk::TestHelpers::Assistant.new(base_url:)
        @profile = profile
        @results = nil
      end

      def run(scenarios)
        @results = scenarios.map do |scenario|
          verdict = scenario.call(@client, @profile)

          if verdict.skipped
            reason = verdict.detail.delete_prefix("SKIP — ")
            puts "  SKIP    — #{scenario.name} (#{reason})"
          elsif verdict.blocked
            # The status says which gate answered.
            puts "  BLOCKED ✓ #{scenario.name} (HTTP #{verdict.status})"
          else
            puts "  BREACH  ✗ #{scenario.name} — #{verdict.detail}"
          end

          { scenario:, verdict: }
        end
      end

      def breaches
        return [] unless @results

        @results.reject { |r| r[:verdict].skipped || r[:verdict].blocked }
      end

      def blocked
        return [] unless @results

        @results.select { |r| !r[:verdict].skipped && r[:verdict].blocked }
      end

      # Never green without at least one proof: a battery that skipped everything proved nothing.
      def all_blocked?
        return false if @results.nil? || @results.empty?

        breaches.empty? && blocked.any?
      end
    end
  end
end
