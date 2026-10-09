# frozen_string_literal: true

module Kiosk
  module TestHelpers
    # `include Kiosk::TestHelpers` in a Minitest class also brings the journey DSL and assertions.
    def self.included(base)
      base.include(Kiosk::TestHelpers::Journey)
      base.include(Kiosk::RLSMinitest::Assertions)
    end
  end
end
