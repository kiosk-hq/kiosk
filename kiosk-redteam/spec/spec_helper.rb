# frozen_string_literal: true

require "kiosk/redteam"
require "webmock/rspec"

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

  # WebMock: disallow real HTTP in specs by default.
  # Individual examples may re-enable using WebMock.allow_net_connect!
  config.before(:suite) { WebMock.disable_net_connect! }

  # Every registration now begins with a proof-of-possession challenge fetch
  # (GET /kiosk/auth/challenge). Stub it broadly so scenario/client specs only
  # have to stub the register POST; a specific example may still override this.
  config.before(:each) do
    stub_request(:get, %r{/kiosk/auth/challenge}).to_return(
      status:  200,
      body:    JSON.generate("challenge" => "test-nonce", "exp" => Time.now.to_i + 120),
      headers: { "Content-Type" => "application/json" },
    )
  end
end
