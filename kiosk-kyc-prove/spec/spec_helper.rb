# frozen_string_literal: true

require "kiosk/kyc_providers/prove"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec)   { |c| c.verify_partial_doubles = true }
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = true
end
