# frozen_string_literal: true

require 'rspec/expectations'

require 'kiosk/test_helpers/skill_pin'

# `expect(Kiosk.configuration).to pin_the_served_skill(hashed_version: '0.6.25')`
# The matcher DSL gives the keywords to the block as one Hash.
RSpec::Matchers.define :pin_the_served_skill do |options|
  match do |configuration|
    @problem = Kiosk::TestHelpers::SkillPin.problem(hashed_version: options.fetch(:hashed_version), configuration:)
    @problem.nil?
  end

  failure_message { @problem }
  description { 'pin the SHA-256 of the skill that kiosk-server gives' }
end
