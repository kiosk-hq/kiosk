# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Redteam::Runner, "against an https origin" do
  it "drives a scenario over TLS" do
    stub_request(:get, %r{\Ahttps://provider\.test/kiosk/auth/challenge})
      .to_return(json_return(200, "challenge" => "nonce", "exp" => Time.now.to_i + 120))
    stub_request(:post, "https://provider.test/kiosk/auth/register").to_return(problem_return("forbidden"))

    reached = Class.new(Kiosk::Redteam::Scenario) do
      def call(client, _profile)
        response = client.register_raw(pow: :skip)
        Kiosk::Redteam::Verdict.new(blocked: Kiosk::Redteam.blocked?(response), skipped: false,
                                    status: response.status, detail: "")
      end
    end.new(name: "reaches the origin", category: "wire", description: "the battery can dial a TLS deployment")

    runner = described_class.new(base_url: "https://provider.test", profile: Kiosk::Redteam::Profile.new)
    runner.run([reached])

    expect(runner.all_blocked?).to be(true)
    expect(a_request(:post, "https://provider.test/kiosk/auth/register")).to have_been_made
  end
end
