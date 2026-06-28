# frozen_string_literal: true

module Kiosk
  module Redteam
    # Base class for all adversarial scenarios.
    #
    # Subclasses (in Task 2) override {#call} to drive a hostile request
    # sequence against the provider and return a {Verdict}.
    #
    # A scenario PASSES (blocked: true) when the provider correctly rejects
    # the attack.  A scenario that finds a real breach must return
    # blocked: false — the Runner then exits non-zero.
    #
    # @abstract Override {#call} in subclasses.
    class Scenario
      # @return [String] short human-readable name used in Runner output
      attr_reader :name

      # @return [String] attack category (e.g. "authorization", "mandate", "kyc")
      attr_reader :category

      # @return [String] description of what this scenario tests
      attr_reader :description

      def initialize(name:, category:, description:)
        @name        = name
        @category    = category
        @description = description
      end

      # Execute the adversarial scenario.
      #
      # @param client  [Client]  HTTP driver pointed at the provider under test
      # @param profile [Object]  provider-specific Profile (Task 2)
      # @return [Verdict]
      def call(client, profile) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end
    end
  end
end
