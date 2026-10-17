# frozen_string_literal: true

require 'kiosk/reputation'

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

  # Reset the backend registry between examples to avoid cross-test pollution.
  config.before(:each) { Kiosk::Reputation::Backends.reset! }
end

# PoW backend doubles. Challenge treats alg and params as opaque and calls only
# the backend's .verify, so a double needs .verify alone.
module TestHelpers
  # Registered as "equihash". Accepts the nonce "good" only.
  class StubBackend
    def self.verify(nonce:, **) # rubocop:disable Naming/PredicateMethod -- the PoW backend interface name.
      nonce.to_s == 'good'
    end
  end

  # Raises when .verify is called: proves that the cheap checks (sig, expiry)
  # answer before the expensive backend evaluation.
  class SpyRaisingBackend
    def self.verify(**)
      raise 'SpyRaisingBackend#verify called — ' \
            'the expensive backend eval must NOT be reached before sig/expiry checks pass'
    end
  end
end
