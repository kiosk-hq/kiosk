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

      # Raised by any conformance check when no origin is wired. An origin is
      # what tells the checks which verbs this app declares, how to reach its
      # router and how to call a verb as a principal; without one there is
      # nothing to check.
      class OriginNotConfigured < StandardError
        DEFAULT_MESSAGE = <<~MSG.strip
          Kiosk::TestHelpers::Conformance has no origin configured.

          Wire one in your test helper:

            # spec/spec_helper.rb or test/test_helper.rb
            require "kiosk/server/conformance_origin"
            Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

          For unit-shaped tests with no Rails and no database, use the bundled
          NullOrigin:

            Kiosk::TestHelpers::Conformance.origin =
              Kiosk::TestHelpers::Conformance::NullOrigin.new
        MSG

        def initialize(message = DEFAULT_MESSAGE)
          super
        end
      end

      # Raised when a conformance check needs to validate a payload against a
      # declared schema and no JSON Schema implementation is loadable. An origin
      # backed by the Kiosk engine never reaches this — json_schemer is a
      # runtime dependency of kiosk-server — so it names the one case that does:
      # a bare origin in an app that has not got one.
      class SchemaValidatorMissing < StandardError
        DEFAULT_MESSAGE = <<~MSG.strip
          Checking a verb's answer against its declared output_schema needs a
          JSON Schema implementation, and `require "json_schemer"` failed.

          Add it to your test group:

            gem "json_schemer"

          An app running kiosk-server already has it: wire
          Kiosk::Server::ConformanceOrigin, which validates through the engine's
          own checker, so the test and the running server cannot disagree.
        MSG

        def initialize(message = DEFAULT_MESSAGE)
          super
        end
      end
    end
  end
end
