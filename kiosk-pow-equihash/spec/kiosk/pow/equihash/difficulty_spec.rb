# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Pow::Equihash::Difficulty do
  around do |example|
    previous = ENV.fetch("KIOSK_POW_DIFFICULTY", nil)
    example.run
  ensure
    ENV["KIOSK_POW_DIFFICULTY"] = previous
  end

  describe ".level" do
    it "reads the knob" do
      ENV["KIOSK_POW_DIFFICULTY"] = "high"

      expect(described_class.level).to eq("high")
    end

    it "tolerates surrounding whitespace and casing" do
      ENV["KIOSK_POW_DIFFICULTY"] = "  HIGH \n"

      expect(described_class.level).to eq("high")
    end

    # The fallback is the whole safety property: an operator who mistypes the
    # knob must not accidentally price every registration at ten seconds.
    it "falls back to the default when unset, blank or unrecognised" do
      [nil, "", "   ", "medium", "168/7", "0"].each do |value|
        ENV["KIOSK_POW_DIFFICULTY"] = value

        expect(described_class.level).to eq(described_class::DEFAULT)
      end
    end
  end

  describe ".params" do
    it "answers a pair the verifier accepts, at both levels" do
      described_class::LEVELS.each_key do |lvl|
        ENV["KIOSK_POW_DIFFICULTY"] = lvl

        expect(Kiosk::Pow::Equihash.valid_params?(described_class.params))
          .to be(true), "#{lvl} is not a solvable parameter pair"
      end
    end

    it "prices the heavy level at the gem's own shipped default" do
      ENV["KIOSK_POW_DIFFICULTY"] = "high"

      expect(described_class.params)
        .to eq(n: Kiosk::Pow::Equihash::DEFAULT_N, k: Kiosk::Pow::Equihash::DEFAULT_K)
    end

    it "prices the default level below the heavy one" do
      low  = described_class::LEVELS.fetch("low")
      high = described_class::LEVELS.fetch("high")

      expect(low[:n] / (low[:k] + 1)).to be < (high[:n] / (high[:k] + 1))
    end
  end

  describe ".pow_notice" do
    it "is absent at the default level — there is nothing to warn about" do
      ENV["KIOSK_POW_DIFFICULTY"] = nil

      expect(described_class.high?).to be(false)
      expect(described_class.pow_notice).to be_nil
    end

    # The notice states a cost, and a hand-typed cost is one an operator can
    # falsify by setting the knob. It must be read off the active params.
    it "names the parameters actually in force" do
      ENV["KIOSK_POW_DIFFICULTY"] = "high"
      p = described_class.params

      expect(described_class.high?).to be(true)
      expect(described_class.pow_notice).to include("n=#{p[:n]} k=#{p[:k]}")
    end
  end
end
