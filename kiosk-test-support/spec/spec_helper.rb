# frozen_string_literal: true

require "kiosk/test_helpers"

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

  config.before(:each) do
    Kiosk.reset!
    Kiosk::TestHelpers.reset!
  end
end

# Minimal stand-in for an ActiveRecord user row — enough to exercise
# user_id / role extraction without dragging Rails in.
FakeUser = Struct.new(:id, :role)
