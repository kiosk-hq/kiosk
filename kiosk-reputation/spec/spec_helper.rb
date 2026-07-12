# frozen_string_literal: true

require "kiosk/reputation"

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

  # Reset the backend registry between examples to avoid cross-test pollution.
  config.before(:each) { Kiosk::Reputation::Backends.reset! }
end

# ---------------------------------------------------------------------------
# StubBackend — registered as "equihash" in tests that need a PoW backend.
#
# The Challenge module is algorithm-agnostic: .issue/.verify treat alg/params
# as opaque and only call the backend's .verify. So these doubles need .verify
# alone — no .params dial (equihash memory is fixed by (n,k); the policy
# escalates by PROOF COUNT, not by params).
#
# .verify returns true iff nonce == "good" (any other value is a "bad proof").
# ---------------------------------------------------------------------------
module TestHelpers
  class StubBackend
    def self.verify(salt:, params:, nonce:)
      nonce.to_s == "good"
    end
  end

  # SpyBackend — raises immediately if .verify is called.
  # Use this to prove the anti-DoS ordering: if the backend is invoked before
  # the cheap checks (sig / expiry) have passed, the suite fails loudly.
  class SpyRaisingBackend
    def self.verify(salt:, params:, nonce:)
      raise "SpyRaisingBackend#verify called — " \
            "the expensive backend eval must NOT be reached before sig/expiry checks pass"
    end
  end
end
