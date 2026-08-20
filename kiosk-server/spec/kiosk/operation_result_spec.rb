# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::OperationResult do
  # The shape every operator writes: subclass, declare the codes THIS app
  # refuses with. Two codes here, deliberately not the wire's fourteen.
  #
  # (`const_set` rather than a `STATUSES = …` line inside the block: a constant
  # assigned in a `Class.new do … end` block lands in the LEXICAL scope — here,
  # Object — not on the anonymous class. In a real `class Foo < Bar` body, which
  # is what an operator writes, the plain assignment is correct.)
  let(:subclass) do
    Class.new(described_class).tap do |klass|
      klass.const_set(:STATUSES, { "bad_request" => :bad_request, "kyc_required" => :forbidden }.freeze)
    end
  end

  describe ".ok" do
    it "carries the value and is not a refusal" do
      result = subclass.ok({ "order_id" => "abc" })

      expect(result).to be_ok
      expect(result.value).to eq({ "order_id" => "abc" })
      expect(result.code).to be_nil
      expect(result.message).to be_nil
      expect(result.hint).to be_nil
    end

    it "returns an instance of the SUBCLASS, so its STATUSES are the ones consulted" do
      expect(subclass.ok(nil)).to be_a(subclass)
    end
  end

  describe ".refused" do
    it "carries code, message and hint, and is not ok" do
      result = subclass.refused(code: "bad_request", message: "party_size must be >= 1", hint: "try 2")

      expect(result).not_to be_ok
      expect(result.code).to eq("bad_request")
      expect(result.message).to eq("party_size must be >= 1")
      expect(result.hint).to eq("try 2")
      expect(result.value).to be_nil
    end

    it "leaves the hint nil when the refusal has nothing to add" do
      expect(subclass.refused(code: "bad_request", message: "no").hint).to be_nil
    end
  end

  it "freezes the instance — a result is a value, not a mutable buffer" do
    expect(subclass.ok({})).to be_frozen
  end

  describe "#status" do
    it "maps the code through the SUBCLASS's table" do
      expect(subclass.refused(code: "bad_request", message: "x").status).to eq(:bad_request)
    end

    # The load-bearing case for keeping the table per-app: the wire vocabulary
    # is not injective, so the status cannot be derived from the code by any
    # shared rule.
    it "lets two different codes map to the same HTTP status" do
      expect(subclass.refused(code: "kyc_required", message: "x").status).to eq(:forbidden)
    end

    it "raises naming the unmapped code rather than guessing a status" do
      expect { subclass.refused(code: "conflict", message: "x").status }
        .to raise_error(KeyError, /STATUSES has no mapping for "conflict"/)
    end

    it "raises the same way when a subclass declares no STATUSES at all" do
      bare = Class.new(described_class)

      expect { bare.refused(code: "bad_request", message: "x").status }
        .to raise_error(KeyError, /has no mapping for "bad_request"/)
    end
  end

  it "ships an empty STATUSES on the base class — it refuses nothing on its own" do
    expect(described_class::STATUSES).to eq({})
    expect(described_class::STATUSES).to be_frozen
  end
end
