# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/skill_pin'

# kiosk-server gives the skill URL. config/initializers/kiosk.rb sets
# skill_sha256, the SHA-256 of that skill file. This test fails when an update
# of kiosk-server gives a different skill version, and tells how to make the
# new digest.
class KioskSkillPinTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::SkillPin::Assertions

  test 'skill_sha256 is the digest of the skill that kiosk-server gives' do
    assert_kiosk_skill_pin hashed_version: '0.6.22'
  end
end
