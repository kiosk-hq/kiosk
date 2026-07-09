# frozen_string_literal: true

require "kiosk"

require "kiosk/test_helpers/version"
require "kiosk/test_helpers/errors"
require "kiosk/test_helpers/null_executor"
require "kiosk/test_helpers/journey"

module Kiosk
  # Test-support primitives for Kiosk providers — the journey-test DSL
  # (`Journey`), the pluggable executor contract, the `NullExecutor`
  # reference implementation, and the structured error classes.
  #
  # Two thin framework wrappers consume this module:
  #
  #   - `kiosk-rls-rspec` — registers `type: :kiosk_journey` and matchers
  #     (`be_rls_denied`, `be_quota_exceeded`).
  #   - `kiosk-rls-minitest` — provides `assert_rls_denied`,
  #     `assert_quota_exceeded`, and an include-and-go module.
  #
  # See design spec §12.
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
