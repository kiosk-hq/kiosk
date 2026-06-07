# frozen_string_literal: true

RSpec.describe Kiosk::TestHelpers::Journey do
  # Bind the DSL onto a fresh class — mirrors what kiosk-rls-rspec /
  # kiosk-rls-minitest do at include time.
  let(:harness_class) { Class.new { include Kiosk::TestHelpers::Journey } }
  let(:harness)       { harness_class.new }
  let(:executor)      { Kiosk::TestHelpers::NullExecutor.new }
  let(:alice)         { FakeUser.new("u-alice", "customer") }
  let(:bob)           { FakeUser.new("u-bob",   "customer") }

  before do
    Kiosk::TestHelpers.executor = executor
    Kiosk.configure { |c| c.roles = %i[customer master] }
  end

  describe "#as_agent_of" do
    it "scopes the block with an agent identity for the user" do
      observed = nil
      harness.as_agent_of(alice) { observed = executor.current_identity }

      expect(observed.user_id).to  eq("u-alice")
      expect(observed.role).to     eq("customer")
      expect(observed.actor).to    eq("agent")
      expect(observed.agent_id).to be_a(String)
    end

    it "generates a fresh agent_id per call" do
      ids = []
      harness.as_agent_of(alice) { ids << executor.current_identity.agent_id }
      harness.as_agent_of(alice) { ids << executor.current_identity.agent_id }
      expect(ids.uniq.size).to eq(2)
    end

    it "respects an explicit role override" do
      harness.as_agent_of(alice, role: :master) do
        expect(executor.current_identity.role).to eq("master")
      end
    end

    it "falls back to the first configured role when the user has none" do
      bare = Struct.new(:id).new("u-x")
      harness.as_agent_of(bare) do
        expect(executor.current_identity.role).to eq("customer")
      end
    end

    it "raises ArgumentError when called without a block" do
      expect { harness.as_agent_of(alice) }.to raise_error(ArgumentError, /block/)
    end
  end

  describe "#as_user" do
    it "scopes with a human identity (no agent_id)" do
      harness.as_user(alice) do
        ident = executor.current_identity
        expect(ident.actor).to    eq("human")
        expect(ident.agent_id).to be_nil
        expect(ident.user_id).to  eq("u-alice")
      end
    end
  end

  describe "#as_agent" do
    it "scopes a synthetic-user agent under a label" do
      harness.as_agent("greenfield-1") do
        ident = executor.current_identity
        expect(ident.user_id).to eq("synthetic:greenfield-1")
        expect(ident.actor).to   eq("agent")
      end
    end

    it "yields the same synthetic user_id across calls with the same label" do
      seen = []
      harness.as_agent("alpha") { seen << executor.current_identity.user_id }
      harness.as_agent("alpha") { seen << executor.current_identity.user_id }
      expect(seen.uniq).to eq(["synthetic:alpha"])
    end
  end

  describe "#as_anonymous" do
    it "scopes with nil identity (no GUCs set)" do
      harness.as_anonymous { expect(executor.current_identity).to be_nil }
    end
  end

  describe "#query" do
    it "delegates to the executor" do
      executor.enqueue_query([{ "n" => 1 }])
      result = harness.as_user(alice) { harness.query("select 1") }
      expect(result).to eq([{ "n" => 1 }])
    end

    it "records the call with the current identity" do
      harness.as_agent_of(alice) { harness.query("select * from orders") }
      call = executor.calls_of(:query).first
      expect(call.identity.user_id).to eq("u-alice")
      expect(call.args[:sql]).to       eq("select * from orders")
    end
  end

  describe "#run_action" do
    it "delegates name + kwargs" do
      harness.as_agent_of(alice) do
        harness.run_action(:create_order, items: ["bread"])
      end
      call = executor.calls_of(:run_action).first
      expect(call.args).to eq(name: :create_order, args: { items: ["bread"] })
    end
  end

  describe "#pay_action" do
    it "delegates under :pay_action kind" do
      harness.as_agent_of(alice) { harness.pay_action(:buy, sku: "x") }
      expect(executor.calls_of(:pay_action).size).to eq(1)
    end
  end

  describe "#kiosk_seed" do
    it "delegates table + attrs + count" do
      harness.kiosk_seed(:rentals, count: 2, active: true)
      call = executor.calls_of(:seed).first
      expect(call.args).to eq(table: :rentals, attrs: { active: true }, count: 2)
    end

    it "expands `owner:` to user_id" do
      harness.kiosk_seed(:rentals, owner: alice)
      call = executor.calls_of(:seed).first
      expect(call.args[:attrs]).to eq(user_id: "u-alice")
    end
  end

  describe "without an executor wired" do
    before { Kiosk::TestHelpers.reset! }

    it "raises on as_agent_of" do
      expect { harness.as_agent_of(alice) {} }
        .to raise_error(Kiosk::TestHelpers::Errors::ExecutorNotConfigured)
    end

    it "raises on query" do
      expect { harness.query("x") }
        .to raise_error(Kiosk::TestHelpers::Errors::ExecutorNotConfigured)
    end
  end
end
