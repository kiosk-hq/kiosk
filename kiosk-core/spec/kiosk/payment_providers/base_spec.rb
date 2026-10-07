# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Base do
  subject(:adapter) { described_class.new }

  describe "#setup_required?" do
    it "returns false (default — StubPsp and SetupIntent-less adapters are never gated)" do
      expect(adapter.setup_required?(user_id: "user-1")).to be(false)
    end
  end

  describe "#setup_url" do
    it "raises NotImplementedError — an adapter whose setup_required? can answer true must implement it" do
      expect {
        adapter.setup_url(user_id: "user-1", return_url: "https://shop.example/kiosk/payment_setup/return")
      }.to raise_error(NotImplementedError, /setup_url must be implemented/)
    end
  end

  describe "#capture" do
    it "raises NotImplementedError — subclasses must implement the charge" do
      expect {
        adapter.capture(:cart_mandate, payment_method: "pm_card_visa")
      }.to raise_error(NotImplementedError, /capture must be implemented/)
    end
  end
end
