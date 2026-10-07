# frozen_string_literal: true

require "kiosk/redteam/stripe_mock"

RSpec.describe Kiosk::Redteam::StripeMock do
  it "answers the base URL of a listening stripe-mock" do
    skip "stripe-mock not installed (brew install stripe-mock)" unless system("command -v stripe-mock >/dev/null 2>&1")

    expect(described_class.start).to eq("http://127.0.0.1:12111")
    expect(described_class.listening?).to be(true)
  end
end
