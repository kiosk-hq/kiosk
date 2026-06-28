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
    #   exit 1 unless runner.all_blocked?
    #
    # Output per scenario:
    #   "  BLOCKED ✓ <name>"           — attack correctly blocked
    #   "  BREACH  ✗ <name> — <detail>" — attack NOT blocked (real finding)
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

          if verdict.blocked
            puts "  BLOCKED ✓ #{scenario.name}"
          else
            puts "  BREACH  ✗ #{scenario.name} — #{verdict.detail}"
          end

          { scenario:, verdict: }
        end
      end

      # @return [Boolean] true only when every scenario in the last {#run} was blocked
      def all_blocked?
        return false if @results.nil? || @results.empty?

        @results.all? { |r| r[:verdict].blocked }
      end
    end
  end
end
