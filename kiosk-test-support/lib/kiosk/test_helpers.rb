# frozen_string_literal: true

require "kiosk"

require "kiosk/test_helpers/version"
require "kiosk/test_helpers/errors"
require "kiosk/test_helpers/null_executor"
require "kiosk/test_helpers/journey"
require "kiosk/test_helpers/conformance"

module Kiosk
  # Test support for Kiosk operators: the journey DSL over a pluggable executor,
  # and the conformance checks an origin runs against itself.
  module TestHelpers
    class << self
      # Anything answering the {NullExecutor} contract.
      attr_accessor :executor

      def require_executor!
        executor || raise(Errors::ExecutorNotConfigured)
      end

      def reset!
        @executor = nil
      end
    end
  end
end
