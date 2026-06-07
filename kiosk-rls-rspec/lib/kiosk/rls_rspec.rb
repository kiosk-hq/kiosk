# frozen_string_literal: true

# kiosk-rls-rspec — RSpec wiring for the Kiosk journey-test DSL.
# See design spec §12.

require "rspec/core"
require "kiosk/test_helpers"

require "kiosk/rls_rspec/version"
require "kiosk/rls_rspec/matchers"

module Kiosk
  module RLSRSpec
    # The metadata tags that pull in the journey DSL. `:kiosk_journey` is
    # the deterministic SQL/Action shape; `:kiosk_agent` is reserved for
    # the optional `kiosk-agent-test` companion gem (spec §12.5), which
    # upgrades this same module with a live-LLM driver. Both tags share
    # the same DSL surface so a test can graduate from one to the other
    # without changing the helper calls.
    JOURNEY_TYPES = %i[kiosk_journey kiosk_agent].freeze

    # Register the journey DSL include + per-example executor reset with
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
