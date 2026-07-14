# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # Structured error classes the journey-test DSL raises. Framework-specific
    # matchers (RSpec `be_rls_denied`, Minitest `assert_rls_denied`) look for
    # these by class.
    #
    # The real executor (`Kiosk::Server::TestExecutor` in `kiosk-server`)
    # raises `RLSDenied` when a SQL statement returns an RLS denial.
    # `QuotaExceeded` has no raiser in the shipped executor yet; it exists so
    # the matchers / assertions and the `NullExecutor` can exercise the
    # quota-denial path.
    module Errors
      # Raised when the configured executor reports the SQL or Action was
      # rejected by an RLS policy. The matcher / assertion is the canonical
      # way to assert this — tests rarely raise it directly.
      class RLSDenied < StandardError; end

      # Raised when a quota (per-agent rate, per-user concurrency, etc.) is
      # exceeded by a `run_action` / `pay_action` call.
      class QuotaExceeded < StandardError; end

      # Raised by any DSL method when no executor is wired. The fix is to
      # set `Kiosk::TestHelpers.executor = ...` in your spec / test helper.
      class ExecutorNotConfigured < StandardError
        DEFAULT_MESSAGE = <<~MSG.strip
          Kiosk::TestHelpers has no executor configured.

          Wire one in your test helper:

            # spec/spec_helper.rb or test/test_helper.rb
            require "kiosk/server/test_executor"
            Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new

          For unit-shaped tests, use the bundled NullExecutor:

            Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new
        MSG

        def initialize(message = DEFAULT_MESSAGE)
          super
        end
      end
    end
  end
end
