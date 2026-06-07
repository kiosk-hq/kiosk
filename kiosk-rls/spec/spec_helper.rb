# frozen_string_literal: true

require "kiosk/rls"

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

  # Reset Kiosk.configuration between examples to keep tests independent —
  # this also resets the RLS-specific extension fields (`app_role`,
  # `system_role`, `schema`) since they live as ivars on Configuration.
  config.before(:each) { Kiosk.reset! }
end

# Test helper — a fake host that records emitted SQL instead of running it.
# Used to test {Kiosk::RLS::DSL} without an actual database.
class FakeMigration
  include Kiosk::RLS::DSL

  attr_reader :statements

  def initialize
    @statements = []
  end

  def execute(sql)
    @statements << sql
  end
end
