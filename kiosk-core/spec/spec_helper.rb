# frozen_string_literal: true

require 'kiosk'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.warnings = false

  # Reset Kiosk.configuration between examples to keep tests independent.
  config.before(:each) { Kiosk.reset! }
end

# Slows Configuration allocation so that racing threads meet inside the lazy
# `Kiosk.configuration` slot. The sleep releases the GVL inside that window.
# The prepend is permanent, so the delay is zero outside the helper below.
module SlowConfigurationAllocation
  COUNTER = Mutex.new

  class << self
    # Seconds each allocation sleeps.
    attr_accessor :delay
    # Number of Configuration objects built.
    attr_accessor :built
  end
  self.delay = 0.0
  self.built = 0

  # Prepended to Configuration's singleton class.
  module SlowNew
    def new(...)
      delay = SlowConfigurationAllocation.delay
      sleep(delay) if delay.positive?
      SlowConfigurationAllocation::COUNTER.synchronize { SlowConfigurationAllocation.built += 1 }
      super
    end
  end

  def self.install!
    Kiosk::Configuration.singleton_class.prepend(SlowNew)
  end
end
SlowConfigurationAllocation.install!

# Run +block+ with Configuration allocation slowed to +seconds+, counting the
# allocations it makes, then restore. Yields nothing; returns [value, built].
def with_slow_configuration_allocation(seconds = 0.02)
  SlowConfigurationAllocation.delay = seconds
  SlowConfigurationAllocation.built = 0
  value = yield
  [value, SlowConfigurationAllocation.built]
ensure
  SlowConfigurationAllocation.delay = 0.0
end

# Release +count+ threads at once and collect their values. The latch makes
# them race: without it the first thread finishes before the last starts.
def race(count, &block)
  latch   = Queue.new
  threads = Array.new(count) do
    Thread.new do
      latch.pop
      block.call
    end
  end
  count.times { latch.push(:go) }
  threads.map(&:value)
end
