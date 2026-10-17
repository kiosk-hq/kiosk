# frozen_string_literal: true

# `bundle exec rspec`. The Kiosk conformance wiring is three lines: require the
# engine-backed origin, require the RSpec adapter, and hand the one to the
# other. kiosk-demo-getgrocery is the Minitest spelling of the same.

ENV['RAILS_ENV'] ||= 'test'

require_relative '../config/environment'
require 'kiosk/test_helpers/small_equihash'
require 'rspec/rails'

require 'kiosk/test_helpers/conformance/in_process_origin'
require 'kiosk/test_helpers/conformance/rspec'

Kiosk::TestHelpers::Conformance.origin = Kiosk::TestHelpers::Conformance::InProcessOrigin.new

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!

  # The property answers at once, and accepts, unless an example says otherwise.
  config.before do
    Rails.configuration.x.hoteling.decision_delay_seconds = 0
    Rails.configuration.x.hoteling.decline_rate           = 0
  end
end
