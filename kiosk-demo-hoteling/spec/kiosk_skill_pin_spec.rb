# frozen_string_literal: true

require 'spec_helper'
require 'kiosk/test_helpers/skill_pin/rspec'

# kiosk-server gives the skill URL. config/initializers/kiosk.rb sets
# skill_sha256, the SHA-256 of that skill file. This spec fails when an update
# of kiosk-server gives a different skill version, and tells how to make the
# new digest.
RSpec.describe 'the skill pin' do
  it 'is the digest of the skill that kiosk-server gives' do
    expect(Kiosk.configuration).to pin_the_served_skill(hashed_version: '0.6.16')
  end
end
