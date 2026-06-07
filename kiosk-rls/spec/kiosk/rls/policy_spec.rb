# frozen_string_literal: true

RSpec.describe Kiosk::RLS::Policy do
  let(:valid) do
    {
      name:   "rentals_select",
      action: :select,
      using:  "user_id = kiosk.current_user_id()",
    }
  end

  describe ".new" do
    it "constructs with name, action and a USING predicate" do
      policy = described_class.new(**valid)
      expect(policy.name).to   eq("rentals_select")
      expect(policy.action).to eq(:select)
      expect(policy.using).to  eq("user_id = kiosk.current_user_id()")
      expect(policy.check).to  be_nil
    end

    it "constructs with WITH CHECK only (INSERT policies typically)" do
      policy = described_class.new(name: "rentals_insert", action: :insert, check: "x")
      expect(policy.check).to eq("x")
      expect(policy.using).to be_nil
    end

    it "constructs with both USING and WITH CHECK (UPDATE policies)" do
      policy = described_class.new(name: "rentals_update", action: :update, using: "x", check: "y")
      expect(policy.using).to eq("x")
      expect(policy.check).to eq("y")
    end

    it "coerces action to a symbol" do
      policy = described_class.new(**valid.merge(action: "select"))
      expect(policy.action).to eq(:select)
    end

    it "coerces name to a string" do
      policy = described_class.new(**valid.merge(name: :rentals_select))
      expect(policy.name).to eq("rentals_select")
    end

    it "accepts all five valid action kinds" do
      %i[select insert update delete all].each do |action|
        expect {
          described_class.new(name: "p", action: action, using: "x")
        }.not_to raise_error
      end
    end

    it "rejects unknown action" do
      expect { described_class.new(**valid.merge(action: :truncate)) }
        .to raise_error(ArgumentError, /action must be one of/)
    end

    it "rejects missing both USING and WITH CHECK" do
      expect { described_class.new(name: "p", action: :select) }
        .to raise_error(ArgumentError, /using:.*check:/)
    end

    it "coerces using to a string" do
      policy = described_class.new(name: "p", action: :select, using: 1)
      expect(policy.using).to eq("1")
    end

    it "coerces check to a string" do
      policy = described_class.new(name: "p", action: :insert, check: 1)
      expect(policy.check).to eq("1")
    end
  end

  describe "value equality" do
    it "two policies with same fields are equal" do
      a = described_class.new(**valid)
      b = described_class.new(**valid)
      expect(a).to eq(b)
    end

    it "differing in action makes them unequal" do
      a = described_class.new(**valid)
      b = described_class.new(**valid.merge(action: :all))
      expect(a).not_to eq(b)
    end
  end

  describe "immutability" do
    it "instances are frozen (Data class)" do
      expect(described_class.new(**valid)).to be_frozen
    end
  end
end
