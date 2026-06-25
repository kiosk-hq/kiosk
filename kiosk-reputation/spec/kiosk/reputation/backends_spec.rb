# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Backends do
  let(:stub_backend) { TestHelpers::StubBackend }

  describe ".register / .fetch" do
    it "returns the registered backend" do
      described_class.register("argon2id", stub_backend)
      expect(described_class.fetch("argon2id")).to be(stub_backend)
    end

    it "accepts symbol or string as alg name equivalently" do
      described_class.register(:argon2id, stub_backend)
      expect(described_class.fetch("argon2id")).to be(stub_backend)
    end
  end

  describe ".fetch on an unknown algorithm" do
    it "raises KeyError with a descriptive message" do
      described_class.register("argon2id", stub_backend)
      expect { described_class.fetch("cuckoo") }
        .to raise_error(KeyError, /Unknown PoW backend.*cuckoo.*Known.*argon2id/i)
    end

    it "lists all known algorithms in the error" do
      described_class.register("argon2id", stub_backend)
      described_class.register("cuckoo",   stub_backend)
      expect { described_class.fetch("unknown") }
        .to raise_error(KeyError, /argon2id.*cuckoo/i)
    end
  end

  describe ".known" do
    it "returns an empty array when nothing is registered" do
      expect(described_class.known).to eq([])
    end

    it "returns sorted algorithm names" do
      described_class.register("cuckoo",   stub_backend)
      described_class.register("argon2id", stub_backend)
      expect(described_class.known).to eq(%w[argon2id cuckoo])
    end
  end

  describe ".reset!" do
    it "clears all registrations" do
      described_class.register("argon2id", stub_backend)
      described_class.reset!
      expect(described_class.known).to be_empty
    end
  end
end
