# frozen_string_literal: true

RSpec.describe Kiosk::Identity do
  let(:valid_args) do
    {
      user_id:  "u-123",
      role:     "customer",
      actor:    "agent",
      agent_id: "a-456",
      claims:   { "iss" => "https://acme.example" },
    }
  end

  describe ".new" do
    it "constructs with all valid fields" do
      identity = described_class.new(**valid_args)
      expect(identity.user_id).to  eq("u-123")
      expect(identity.role).to     eq("customer")
      expect(identity.actor).to    eq("agent")
      expect(identity.agent_id).to eq("a-456")
    end

    it "coerces role to string" do
      identity = described_class.new(**valid_args.merge(role: :customer))
      expect(identity.role).to eq("customer")
    end

    it "coerces actor to string" do
      identity = described_class.new(**valid_args.merge(actor: :agent))
      expect(identity.actor).to eq("agent")
    end

    it "rejects missing user_id" do
      expect { described_class.new(**valid_args.merge(user_id: nil)) }
        .to raise_error(ArgumentError, /user_id/)
    end

    it "allows a missing role (ADR-0011: hook-or-absent)" do
      identity = described_class.new(**valid_args.merge(role: nil))
      expect(identity.role).to be_nil
    end

    it "normalizes an empty role to nil" do
      identity = described_class.new(**valid_args.merge(role: ""))
      expect(identity.role).to be_nil
    end

    it "rejects unknown actor" do
      expect { described_class.new(**valid_args.merge(actor: "robot")) }
        .to raise_error(ArgumentError, /actor/)
    end

    it "requires agent_id when actor is agent" do
      expect { described_class.new(**valid_args.merge(agent_id: nil)) }
        .to raise_error(ArgumentError, /agent_id required/)
    end

    it "requires agent_id when actor is agent (empty string)" do
      expect { described_class.new(**valid_args.merge(agent_id: "")) }
        .to raise_error(ArgumentError, /agent_id required/)
    end

    it "forbids agent_id when actor is human" do
      args = valid_args.merge(actor: "human")
      expect { described_class.new(**args) }
        .to raise_error(ArgumentError, /agent_id must be nil/)
    end

    it "allows human actor with no agent_id" do
      identity = described_class.new(**valid_args.merge(actor: "human", agent_id: nil))
      expect(identity).to be_human
      expect(identity.agent_id).to be_nil
    end

    it "allows service actor with no agent_id" do
      identity = described_class.new(**valid_args.merge(actor: "service", agent_id: nil))
      expect(identity).to be_service
    end

    it "defaults claims to empty hash" do
      identity = described_class.new(user_id: "u", role: "customer", actor: "human")
      expect(identity.claims).to eq({})
    end
  end

  describe "predicates" do
    it "#agent? returns true only for agent" do
      expect(described_class.new(**valid_args)).to be_agent
      expect(described_class.new(**valid_args.merge(actor: "human", agent_id: nil))).not_to be_agent
    end

    it "#human? returns true only for human" do
      expect(described_class.new(**valid_args.merge(actor: "human", agent_id: nil))).to be_human
    end

    it "#service? returns true only for service" do
      expect(described_class.new(**valid_args.merge(actor: "service", agent_id: nil))).to be_service
    end
  end

  describe "value equality" do
    it "two identities with same fields are equal" do
      a = described_class.new(**valid_args)
      b = described_class.new(**valid_args)
      expect(a).to eq(b)
    end

    it "differing in user_id makes them unequal" do
      a = described_class.new(**valid_args)
      b = described_class.new(**valid_args.merge(user_id: "u-different"))
      expect(a).not_to eq(b)
    end
  end

  describe "immutability" do
    it "Data class instances are frozen" do
      identity = described_class.new(**valid_args)
      expect(identity).to be_frozen
    end
  end
end
