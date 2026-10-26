# frozen_string_literal: true

# kiosk-rls-rspec — RSpec integration for the Kiosk journey-test DSL.

require 'rspec/core'
require 'kiosk/test_helpers'

require 'kiosk/rls_rspec/version'
require 'kiosk/rls_rspec/matchers'

module Kiosk
  module RLSRSpec
    # The metadata tag that pulls in the journey DSL.
    JOURNEY_TYPES = %i[kiosk_journey].freeze

    # Runs on require; call it yourself only under an unusual load order.
    def self.install!(config = RSpec.configuration)
      JOURNEY_TYPES.each do |type|
        config.include(Kiosk::TestHelpers::Journey, type: type)
      end
    end
  end
end

Kiosk::RLSRSpec.install! if defined?(RSpec) && RSpec.respond_to?(:configuration)
