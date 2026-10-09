# frozen_string_literal: true

require "kiosk/test_helpers"
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

  config.before(:each) do
    Kiosk.reset!
    Kiosk::TestHelpers.reset!
    Kiosk::TestHelpers::Conformance.reset!
  end
end

# Minimal stand-in for an ActiveRecord user row — enough to exercise
# user_id / role extraction without dragging Rails in.
FakeUser = Struct.new(:id, :role)

# A WebMock answer carrying a JSON body.
def json_return(status, body)
  { status:, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
end

# A WebMock answer carrying a problem document for `code`.
def problem_return(code, status: 400, **members)
  json_return(status, { "type" => "https://kiosk.tech/problems/#{code}", "status" => status, "code" => code }
                        .merge(members.transform_keys(&:to_s)))
end
