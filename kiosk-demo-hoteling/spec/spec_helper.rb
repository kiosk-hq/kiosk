# frozen_string_literal: true

# `bundle exec rspec`. The Kiosk conformance wiring is three lines: require the
# engine-backed origin, require the RSpec adapter, and hand the one to the
# other. kiosk-demo-getgrocery is the Minitest spelling of the same.

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rspec/rails"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/rspec"

Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  # `rake check:conformance` loads the test database before this runs.
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
end
