# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # `include Kiosk::TestHelpers` is the documented entry point in spec §12.
    # When mixed into a Minitest test class, also pull in the journey DSL
    # and the Kiosk assertions in one go — no second include needed.
    #
    # The base `Kiosk::TestHelpers` module (in kiosk-test-support) carries
    # only the singleton accessors (`.executor`, `.require_executor!`,
    # `.reset!`) — it does not auto-include into anything. This file
    # extends it with an `included` hook that pulls in the journey DSL +
    # assertions when the host class is a Minitest test.
    def self.included(base)
      base.include(Kiosk::TestHelpers::Journey)
      base.include(Kiosk::RLSMinitest::Assertions)
    end
  end
end
