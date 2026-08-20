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

  # ── the mint-time parameter seam (K-843) ──────────────────────────────────
  #
  # Challenge.issue takes any alg + params Hash and only HMACs them, so a
  # degenerate difficulty is minted happily and only surfaces when an honest
  # solve fails verification — the agent hears "invalid proof of work" for a
  # correct proof and the operator hears nothing. This is the question a gate
  # asks BEFORE it mints. The rule that matters is the negative one: the seam
  # must never invent a refusal it was not told about.
  describe ".valid_params?" do
    let(:strict_backend) do
      Class.new do
        def self.verify(salt:, params:, nonce:) = true
        def self.valid_params?(params) = params.is_a?(Hash) && params[:n].to_i.positive?
      end
    end

    it "delegates to a backend that implements it — false" do
      described_class.register("strict", strict_backend)
      expect(described_class.valid_params?("strict", { n: 0 })).to be(false)
    end

    it "delegates to a backend that implements it — true" do
      described_class.register("strict", strict_backend)
      expect(described_class.valid_params?("strict", { n: 168 })).to be(true)
    end

    it "accepts a Symbol alg name, like .fetch" do
      described_class.register("strict", strict_backend)
      expect(described_class.valid_params?(:strict, { n: 0 })).to be(false)
    end

    it "answers TRUE for a backend that does not implement it (unconstrained)" do
      # StubBackend responds to .verify only. A backend with no opinion about
      # its parameters must not be given one here.
      described_class.register("argon2id", stub_backend)
      expect(described_class.valid_params?("argon2id", { anything: "at all" })).to be(true)
    end

    it "answers TRUE for an UNREGISTERED algorithm rather than raising" do
      # An unregistered alg is a different misconfiguration and .fetch already
      # reports it, naming the algorithms that ARE registered. If this raised
      # instead, a gate calling it would turn that into a mint-time 500 and the
      # operator would lose the message that names the fix.
      expect(described_class.valid_params?("nothing-registered", { n: 168 })).to be(true)
      expect { described_class.fetch("nothing-registered") }.to raise_error(KeyError)
    end
  end

end
