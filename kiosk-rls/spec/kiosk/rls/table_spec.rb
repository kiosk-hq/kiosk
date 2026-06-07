# frozen_string_literal: true

RSpec.describe Kiosk::RLS::Table do
  describe ".new" do
    it "defaults app_role from Kiosk.configuration" do
      table = described_class.new(:rentals)
      expect(table.app_role).to eq("app_role")
    end

    it "respects an explicit app_role override" do
      table = described_class.new(:rentals, app_role: "ro_role")
      expect(table.app_role).to eq("ro_role")
    end

    it "respects Kiosk.configuration.app_role" do
      Kiosk.configure { |c| c.app_role = "agent_role" }
      table = described_class.new(:rentals)
      expect(table.app_role).to eq("agent_role")
    end

    it "stringifies the table name" do
      expect(described_class.new(:rentals).name).to eq("rentals")
    end

    it "accepts sequences as strings" do
      table = described_class.new(:rentals, sequences: %w[rentals_id_seq])
      expect(table.sequences).to eq(["rentals_id_seq"])
    end

    it "stringifies symbol sequences" do
      table = described_class.new(:rentals, sequences: [:rentals_id_seq])
      expect(table.sequences).to eq(["rentals_id_seq"])
    end

    it "starts with no policies and no comment" do
      table = described_class.new(:rentals)
      expect(table.policies).to     be_empty
      expect(table.comment_text).to be_nil
    end
  end

  describe "#policy" do
    subject(:table) { described_class.new(:rentals) }

    it "adds a policy with a default name `<table>_<action>`" do
      table.policy(:select, using: "user_id = kiosk.current_user_id()")
      policy = table.policies.first

      expect(policy.name).to   eq("rentals_select")
      expect(policy.action).to eq(:select)
      expect(policy.using).to  eq("user_id = kiosk.current_user_id()")
    end

    it "respects an explicit name override" do
      table.policy(:select, name: "rentals_owner_or_admin", using: "x")
      expect(table.policies.first.name).to eq("rentals_owner_or_admin")
    end

    it "accumulates multiple policies in order" do
      table.policy(:select, using: "x")
      table.policy(:insert, check: "y")

      expect(table.policies.size).to eq(2)
      expect(table.policies.map(&:action)).to eq(%i[select insert])
    end

    it "propagates Policy validation errors" do
      expect { table.policy(:bogus, using: "x") }
        .to raise_error(ArgumentError, /action must be one of/)
    end
  end

  describe "#comment" do
    subject(:table) { described_class.new(:rentals) }

    it "stores the comment text" do
      table.comment("A scooter rental owned by the renting user.")
      expect(table.comment_text).to eq("A scooter rental owned by the renting user.")
    end

    it "stringifies non-string input" do
      table.comment(:placeholder)
      expect(table.comment_text).to eq("placeholder")
    end
  end

  describe "#validate!" do
    subject(:table) { described_class.new(:rentals) }

    it "raises when comment is missing (spec §7.5)" do
      table.policy(:select, using: "x")
      expect { table.validate! }
        .to raise_error(ArgumentError, /comment/)
    end

    it "raises when comment is empty" do
      table.policy(:select, using: "x")
      table.comment("")
      expect { table.validate! }
        .to raise_error(ArgumentError, /comment/)
    end

    it "passes when comment is present" do
      table.policy(:select, using: "x")
      table.comment("OK.")
      expect(table.validate!).to eq(table)
    end
  end
end
