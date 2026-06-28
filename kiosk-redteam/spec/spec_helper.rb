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
end
