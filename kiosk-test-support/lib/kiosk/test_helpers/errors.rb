# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # Errors this gem raises, from the journey DSL and the conformance checks.
    module Errors
      class RLSDenied < StandardError; end

      # No shipped executor raises this yet; `NullExecutor` can.
      class QuotaExceeded < StandardError; end

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
    end
  end
end
