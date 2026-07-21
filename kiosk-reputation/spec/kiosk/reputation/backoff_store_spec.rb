# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::BackoffStore do
  subject(:store) { described_class.new }

  describe "#consume before any grant" do
    it "returns false (no grant available)" do
      expect(store.consume("k")).to be(false)
    end

    it "returns false repeatedly (never goes negative)" do
      3.times { expect(store.consume("k")).to be(false) }
    end
  end

  describe "#grant then #consume" do
    it "returns true exactly n times, then false" do
      store.grant("k", 3)
      expect(store.consume("k")).to be(true)
      expect(store.consume("k")).to be(true)
      expect(store.consume("k")).to be(true)
      expect(store.consume("k")).to be(false)
    end

    it "decrements to zero and stops (a 4th consume after grant(3) is false)" do
      store.grant("k", 3)
      3.times { store.consume("k") }
      expect(store.consume("k")).to be(false)
    end
  end

  describe "#grant resets rather than accumulates" do
    it "a second grant sets the count (does not add to remaining)" do
      store.grant("k", 3)
      store.consume("k")        # remaining 2
      store.grant("k", 3)       # reset to 3, not 5
      expect(store.consume("k")).to be(true)  # 2
      expect(store.consume("k")).to be(true)  # 1
      expect(store.consume("k")).to be(true)  # 0
      expect(store.consume("k")).to be(false)
    end
  end

  describe "keys are independent" do
    it "consuming one key does not affect another" do
      store.grant("a", 1)
      expect(store.consume("b")).to be(false)
      expect(store.consume("a")).to be(true)
    end
  end

  describe "grant(0)" do
    it "grants nothing (consume is immediately false)" do
      store.grant("k", 0)
      expect(store.consume("k")).to be(false)
    end
  end
end
