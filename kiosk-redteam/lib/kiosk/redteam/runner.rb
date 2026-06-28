# frozen_string_literal: true

module Kiosk
  module Redteam
    # Runs a battery of adversarial scenarios against a Kiosk provider and
    # aggregates the results.
    #
    # Intended to back a rake task:
    #
    #   runner = Kiosk::Redteam::Runner.new(base_url: server_url, profile: profile)
    #   runner.run(scenarios)
    #   exit 1 if runner.breaches.any?
    #
    # Output per scenario:
    #   "  BLOCKED ✓ <name>"              — attack correctly blocked
    #   "  SKIP    — <name> (<reason>)"   — profile lacks the surface (not a pass)
    #   "  BREACH  ✗ <name> — <detail>"   — attack NOT blocked (real finding)
    class Runner
      def initialize(base_url:, profile:)
        @client  = Client.new(base_url:)
        @profile = profile
        @results = nil
      end

      # Run all scenarios and return the results array.
      #
      # @param scenarios [Array<Scenario>] scenarios to run in order
      # @return [Array<Hash{scenario: Scenario, verdict: Verdict}>]
      def run(scenarios)
        @results = scenarios.map do |scenario|
          verdict = scenario.call(@client, @profile)

          if verdict.skipped
            reason = verdict.detail.delete_prefix("SKIP — ")
            puts "  SKIP    — #{scenario.name} (#{reason})"
          elsif verdict.blocked
            puts "  BLOCKED ✓ #{scenario.name}"
          else
            puts "  BREACH  ✗ #{scenario.name} — #{verdict.detail}"
          end

          { scenario:, verdict: }
        end
      end

      # Returns all results where the attack was not rejected and not skipped.
      # An empty array means no breaches (battery clean).
      #
      # @return [Array<Hash{scenario: Scenario, verdict: Verdict}>]
      def breaches
        return [] unless @results

        @results.reject { |r| r[:verdict].skipped || r[:verdict].blocked }
      end

      # @return [Boolean] true only when every non-skipped scenario was blocked
      #   (i.e. no breaches).  Skipped scenarios do NOT count as passes.
      def all_blocked?
        return false if @results.nil? || @results.empty?

        breaches.empty?
      end
    end
  end
end
