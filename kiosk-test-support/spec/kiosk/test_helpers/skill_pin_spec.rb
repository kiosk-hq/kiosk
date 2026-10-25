# frozen_string_literal: true

require 'kiosk/test_helpers/skill_pin/rspec'

RSpec.describe Kiosk::TestHelpers::SkillPin do
  let(:served) { Kiosk::Configuration.new.skill_url }
  let(:version) { served[described_class::VERSION_IN_URL, 1] }
  let(:digest) { 'a' * 64 }

  before { Kiosk.configure { |c| c.skill_sha256 = digest } }

  it 'passes when skill_sha256 is a digest made for the skill kiosk-server gives' do
    expect(Kiosk.configuration).to pin_the_served_skill(hashed_version: version)
  end

  it 'fails after an update of kiosk-server, and tells how to make the new digest' do
    message = described_class.problem(hashed_version: '0.0.1')

    expect(message).to include("skill #{version}, but skill_sha256 is the digest of the skill 0.0.1")
    expect(message).to include("curl -fsS #{served} | shasum -a 256")
    expect(message).to include("hashed_version: '#{version}'")
  end

  it 'never shows a digest it did not get from the operator' do
    message = described_class.problem(hashed_version: '0.0.1')

    expect(message.scan(/\h{64}/)).to be_empty
  end

  it 'fails when skill_sha256 is not set' do
    Kiosk.configure { |c| c.skill_sha256 = nil }

    expect(described_class.problem(hashed_version: version)).to include('skill_sha256 is not set')
  end

  it 'fails when skill_sha256 is not a SHA-256 digest' do
    Kiosk.configure { |c| c.skill_sha256 = 'abc' }

    expect(described_class.problem(hashed_version: version)).to include('is not a SHA-256 digest')
  end

  it 'fails when the configuration sets its own skill_url' do
    Kiosk.configure { |c| c.skill_url = 'https://kiosk.tech/skill-v0.0.1.md' }

    expect(described_class.problem(hashed_version: version)).to include('Remove the line `c.skill_url = ...`')
  end

  it 'gives the Minitest assertion the message' do
    test = Class.new do
      include Kiosk::TestHelpers::SkillPin::Assertions

      attr_reader :asserted

      def assert(passed, message) = @asserted = [passed, message]
    end.new

    test.assert_kiosk_skill_pin(hashed_version: '0.0.1')
    expect(test.asserted).to eq([false, described_class.problem(hashed_version: '0.0.1')])
  end
end
