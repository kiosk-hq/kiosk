# frozen_string_literal: true

RSpec.describe Kiosk::TestHelpers::NullExecutor do
  subject(:executor) { described_class.new }

  let(:identity) do
    Kiosk::Identity.new(user_id: "u1", role: "customer", actor: "human")
  end

  describe "#with_identity" do
    it "pushes and pops the identity stack around the block" do
      observed = nil
      executor.with_identity(identity) { observed = executor.current_identity }
      expect(observed).to eq(identity)
      expect(executor.current_identity).to be_nil
    end

    it "pops even when the block raises" do
      expect {
        executor.with_identity(identity) { raise "boom" }
      }.to raise_error("boom")
      expect(executor.current_identity).to be_nil
    end

    it "supports nested scopes" do
      outer = identity
      inner = Kiosk::Identity.new(user_id: "u2", role: "customer", actor: "human")

      observed = []
      executor.with_identity(outer) do
        observed << executor.current_identity
        executor.with_identity(inner) { observed << executor.current_identity }
        observed << executor.current_identity
      end

      expect(observed).to eq([outer, inner, outer])
    end
  end

  describe "#query" do
    it "records the call with the current identity" do
      executor.with_identity(identity) { executor.query("select 1") }
      call = executor.calls.first
      expect(call.kind).to     eq(:query)
      expect(call.args).to     eq(sql: "select 1")
      expect(call.identity).to eq(identity)
    end

    it "returns [] by default" do
      expect(executor.query("select 1")).to eq([])
    end

    it "returns the queued result FIFO" do
      executor.enqueue_query([{ "n" => 1 }])
      executor.enqueue_query([{ "n" => 2 }])
      expect(executor.query("a")).to eq([{ "n" => 1 }])
      expect(executor.query("b")).to eq([{ "n" => 2 }])
    end

    it "raises RLSDenied when an error is enqueued" do
      executor.enqueue_error(:query, :rls_denied)
      expect { executor.query("x") }
        .to raise_error(Kiosk::TestHelpers::Errors::RLSDenied)
    end
  end

  describe "#run_action" do
    it "records name + args" do
      executor.run_action(:create_order, { items: ["bread"] })
      call = executor.calls_of(:run_action).first
      expect(call.args).to eq(name: :create_order, args: { items: ["bread"] })
    end

    it "raises QuotaExceeded when enqueued" do
      executor.enqueue_error(:run_action, :quota_exceeded)
      expect { executor.run_action(:x, {}) }
        .to raise_error(Kiosk::TestHelpers::Errors::QuotaExceeded)
    end
  end

  describe "#pay_action" do
    it "records under its own kind" do
      executor.pay_action(:buy, { sku: "x" })
      expect(executor.calls_of(:pay_action).size).to eq(1)
      expect(executor.calls_of(:run_action)).to be_empty
    end
  end

  describe "#seed" do
    it "records table, attrs, count" do
      executor.seed(:rentals, { active: true }, count: 3)
      call = executor.calls_of(:seed).first
      expect(call.args).to eq(table: :rentals, attrs: { active: true }, count: 3)
    end
  end

  describe "#calls_of" do
    it "filters by kind" do
      executor.query("a")
      executor.run_action(:x, {})
      executor.query("b")
      expect(executor.calls_of(:query).size).to       eq(2)
      expect(executor.calls_of(:run_action).size).to  eq(1)
    end
  end

  describe "enqueued errors with custom class" do
    it "raises any provided exception class" do
      custom = Class.new(StandardError)
      executor.enqueue_error(:query, custom)
      expect { executor.query("x") }.to raise_error(custom)
    end
  end
end
