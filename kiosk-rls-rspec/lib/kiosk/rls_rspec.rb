# frozen_string_literal: true

# kiosk-rls-rspec — RSpec wiring for the Kiosk journey-test DSL.

require "rspec/core"
require "kiosk/test_helpers"

require "kiosk/rls_rspec/version"
require "kiosk/rls_rspec/matchers"

module Kiosk
  module RLSRSpec
    # The metadata tags that pull in the journey DSL. Both get the SAME
    # surface — they differ only in the name a group tags itself with, so a
    # test can move between them without changing a helper call. Nothing here
    # drives a live model: `:kiosk_agent` is a tag, not a mode.
    JOURNEY_TYPES = %i[kiosk_journey kiosk_agent].freeze

    # Register the journey DSL include for the journey metadata tags with
    # the given RSpec configuration. Called automatically on require if
    # RSpec is already loaded; providers using an unusual load order can
    # invoke it manually.
    #
    # @example
    #   RSpec.configure { |c| Kiosk::RLSRSpec.install!(c) }
    def self.install!(config = RSpec.configuration)
      JOURNEY_TYPES.each do |type|
        config.include(Kiosk::TestHelpers::Journey, type: type)
      end
    end
  end
end

Kiosk::RLSRSpec.install! if defined?(RSpec) && RSpec.respond_to?(:configuration)
