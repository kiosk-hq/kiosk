# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Kiosk::Redteam::Runner do
  describe 'against an https origin' do
    it 'drives a scenario over TLS' do
      stub_request(:post, 'https://provider.test/kiosk/oauth/register').to_return(problem_return('forbidden'))

      reached = Class.new(Kiosk::Redteam::Scenario) do
        def call(client, _profile)
          response = client.register_raw(pow: :skip)
          Kiosk::Redteam::Verdict.new(blocked: Kiosk::Redteam.blocked?(response), skipped: false,
                                      status: response.status, detail: '')
        end
      end.new(name: 'reaches the origin')

      runner = described_class.new(base_url: 'https://provider.test', profile: Kiosk::Redteam::Profile.new)
      results = runner.run([reached])

      expect(results.map { |r| r[:verdict].blocked }).to eq([true])
      expect(a_request(:post, 'https://provider.test/kiosk/oauth/register')).to have_been_made
    end
  end
end
