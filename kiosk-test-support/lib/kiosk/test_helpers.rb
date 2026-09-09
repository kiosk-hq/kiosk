# frozen_string_literal: true

require "kiosk"

require "kiosk/test_helpers/version"
require "kiosk/test_helpers/errors"
require "kiosk/test_helpers/null_executor"
require "kiosk/test_helpers/journey"
require "kiosk/test_helpers/conformance"

module Kiosk
  # Test-support primitives for Kiosk providers — the journey-test DSL
  # (`Journey`), the pluggable executor contract, the `NullExecutor`
  # reference implementation, the structured error classes, and the
  # conformance checks ({Conformance}) an origin runs against itself.
  #
  # Two thin framework wrappers consume the journey half:
  #
  #   - `kiosk-rls-rspec` — registers `type: :kiosk_journey` and matchers
  #     (`be_rls_denied`, `be_quota_exceeded`).
  #   - `kiosk-rls-minitest` — provides `assert_rls_denied`,
  #     `assert_quota_exceeded`, and an include-and-go module.
  #
  # The conformance half ships its own two adapters INSIDE this gem, loaded by
  # explicit require and never on this path, so the gem still depends on no
  # test framework:
  #
  #   - `kiosk/test_helpers/conformance/minitest` — the four assertions.
  #   - `kiosk/test_helpers/conformance/rspec` — the four matchers.
  #
  # They live here rather than beside the journey wrappers because those two
  # gems are named for row-level security, which is OPT-IN, while the four
  # properties the conformance checks assert are normative of every origin
  # whether or not it uses RLS.
  #
  module TestHelpers
    class << self
      # The active executor — anything responding to the contract documented
      # on {NullExecutor}. Defaults to `nil`; any DSL call will then raise
      # {Errors::ExecutorNotConfigured} with a helpful wiring hint.
      attr_accessor :executor

      # Raise {Errors::ExecutorNotConfigured} unless an executor is wired.
      # Returns the executor for chaining: `TestHelpers.require_executor!.query(...)`.
      def require_executor!
        executor || raise(Errors::ExecutorNotConfigured)
      end

      # Drop the configured executor — primarily for between-test cleanup.
      def reset!
        @executor = nil
      end
    end
  end
end
