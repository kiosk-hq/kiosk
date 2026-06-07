# frozen_string_literal: true

RSpec.describe Kiosk::TestHelpers do
  describe ".executor" do
    it "defaults to nil" do
      expect(described_class.executor).to be_nil
    end

    it "is assignable" do
      executor = Kiosk::TestHelpers::NullExecutor.new
      described_class.executor = executor
      expect(described_class.executor).to be(executor)
    end
  end

  describe ".require_executor!" do
    it "returns the executor when set" do
      executor = Kiosk::TestHelpers::NullExecutor.new
      described_class.executor = executor
      expect(described_class.require_executor!).to be(executor)
    end

    it "raises ExecutorNotConfigured when unset" do
      expect { described_class.require_executor! }
        .to raise_error(Kiosk::TestHelpers::Errors::ExecutorNotConfigured)
    end

    it "includes a wiring hint in the default message" do
      error = nil
      begin
        described_class.require_executor!
      rescue Kiosk::TestHelpers::Errors::ExecutorNotConfigured => e
        error = e
      end
      expect(error.message).to match(/Kiosk::TestHelpers.executor/)
    end
  end

  describe ".reset!" do
    it "clears the configured executor" do
      described_class.executor = Kiosk::TestHelpers::NullExecutor.new
      described_class.reset!
      expect(described_class.executor).to be_nil
    end
  end
end
