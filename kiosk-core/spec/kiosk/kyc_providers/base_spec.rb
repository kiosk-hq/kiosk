# frozen_string_literal: true

RSpec.describe Kiosk::KycProviders::Base do
  subject(:provider) { described_class.new }

  describe "#open_verification" do
    it "raises NotImplementedError — an adapter must open the verification" do
      expect {
        provider.open_verification(subject: "user-1", claims: %w[age_over_18], audience: "shop",
                                   callback_url: "https://shop.example/kiosk/kyc/callback")
      }.to raise_error(NotImplementedError, /open_verification must be implemented/)
    end
  end

  describe "#accepts?" do
    it "accepts every attestation the engine verified" do
      expect(provider.accepts?({ "sub" => "user-1" })).to be(true)
    end
  end

  it "is configured on Kiosk.configuration.kyc_provider, nil by default" do
    expect(Kiosk::Configuration.new.kyc_provider).to be_nil
  end
end
