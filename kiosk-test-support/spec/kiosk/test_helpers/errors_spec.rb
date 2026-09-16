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

  describe described_class::OriginNotConfigured do
    it "has a default message pointing at the wiring API" do
      expect(described_class.new.message).to match(/Kiosk::TestHelpers::Conformance\.origin/)
    end
  end

  # K-1701. This class carried five lines of wiring advice that no run had ever
  # produced — the only mention of it anywhere outside this gem's `lib` was its
  # own `raise` site. The advice is the whole point of the class, so it is the
  # thing asserted: both halves of it, the gem to add and the engine-backed
  # alternative that makes the question moot.
  describe described_class::SchemaValidatorMissing do
    it "names the gem to add and the engine-backed origin that needs none" do
      message = described_class.new.message

      expect(message).to include('gem "json_schemer"')
      expect(message).to include("Kiosk::Server::ConformanceOrigin")
    end

    it "accepts a custom message" do
      expect(described_class.new("custom").message).to eq("custom")
    end
  end
end
