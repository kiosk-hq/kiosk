# frozen_string_literal: true

RSpec.describe Kiosk::TestHelpers::Errors do
  describe described_class::RLSDenied do
    it "is a StandardError subclass" do
      expect(described_class.new).to be_a(StandardError)
    end
  end

  describe described_class::QuotaExceeded do
    it "is a StandardError subclass" do
      expect(described_class.new).to be_a(StandardError)
    end
  end

  describe described_class::ExecutorNotConfigured do
    it "has a default message pointing at the wiring API" do
      expect(described_class.new.message).to match(/Kiosk::TestHelpers\.executor/)
    end

    it "accepts a custom message" do
      expect(described_class.new("custom").message).to eq("custom")
    end
  end
end
