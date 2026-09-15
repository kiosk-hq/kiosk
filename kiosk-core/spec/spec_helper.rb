# frozen_string_literal: true

require "kiosk"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = false

  # Reset Kiosk.configuration between examples to keep tests independent.
  config.before(:each) { Kiosk.reset! }
end

# ── K-1619: force the interleaving at the lazy `Kiosk.configuration` slot ────
#
# Hoping for the race does not work — the pre-fix window between the ivar read
# and the ivar write is sub-microsecond, and K-1610 measured 0 failures in 2000
# trials of 20 racing threads on the identical shape one level down. So the
# allocation itself is slowed, which releases the GVL exactly inside the
# window; the shipped code is otherwise untouched.
module SlowConfigurationAllocation
  # Mutable because the prepend below is permanent (a module cannot be
  # un-prepended) while the delay must be off for every other example.
  DELAY = { seconds: 0.0 }

  # Counts every Configuration actually built, which is the property under
  # test: pre-fix a racing first touch builds N of them and keeps the last.
  BUILT = { count: 0 }
  COUNTER = Mutex.new

  module SlowNew
    def new(*args, **kwargs, &blk)
      seconds = SlowConfigurationAllocation::DELAY[:seconds]
      sleep(seconds) if seconds > 0
      SlowConfigurationAllocation::COUNTER.synchronize do
        SlowConfigurationAllocation::BUILT[:count] += 1
      end
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
  SlowConfigurationAllocation::DELAY[:seconds]  = seconds
  SlowConfigurationAllocation::BUILT[:count]    = 0
  value = yield
  [value, SlowConfigurationAllocation::BUILT[:count]]
ensure
  SlowConfigurationAllocation::DELAY[:seconds] = 0.0
end

# Release +n+ threads at once and collect their values. The latch is what makes
# them race: without it the first thread finishes before the last is spawned.
def race(n, &block)
  latch   = Queue.new
  threads = Array.new(n) { Thread.new { latch.pop; block.call } }
  n.times { latch.push(:go) }
  threads.map(&:value)
end
