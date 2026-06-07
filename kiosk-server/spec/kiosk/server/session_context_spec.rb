# frozen_string_literal: true

RSpec.describe Kiosk::Server::SessionContext do
  let(:connection) { FakeConnection.new }

  describe ".open with agent identity" do
    it "opens a transaction and yields self" do
      yielded = nil
      described_class.open(connection: connection, identity: build_identity(actor: "agent")) do |s|
        yielded = s
        expect(connection.in_transaction?).to be(true)
      end

      expect(yielded).to be_a(described_class)
      expect(connection.in_transaction?).to be(false)
    end

    it "emits SET LOCAL for all four GUCs (agent path)" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "agent", user_id: "u-1", role: "customer", agent_id: "a-1"),
      ) { }

      expect(connection.executed_sql).to eq([
        "SET LOCAL app.current_user_id = 'u-1'",
        "SET LOCAL app.current_role = 'customer'",
        "SET LOCAL app.current_actor = 'agent'",
        "SET LOCAL app.current_agent_id = 'a-1'",
      ])
    end

    it "skips the agent_id SET LOCAL for human/service actors (agent_id nil)" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "human", agent_id: nil),
      ) { }

      expect(connection.executed_sql).to eq([
        "SET LOCAL app.current_user_id = 'u-1'",
        "SET LOCAL app.current_role = 'customer'",
        "SET LOCAL app.current_actor = 'human'",
      ])
    end

    it "uses the configured GUC namespace" do
      Kiosk.configure { |c| c.guc_namespace = "kiosk" }
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "agent"),
      ) { }

      expect(connection.executed_sql.first).to eq("SET LOCAL kiosk.current_user_id = 'u-1'")
    end

    it "escapes single-quotes in identity values" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "human", agent_id: nil, user_id: "it's-u"),
      ) { }

      expect(connection.executed_sql.first).to include("'it''s-u'")
    end
  end

  describe "#guc_statements" do
    it "returns the SQL strings without executing" do
      ctx = described_class.new(connection: connection, identity: build_identity(actor: "agent"))
      stmts = ctx.guc_statements

      expect(stmts.size).to eq(4)
      expect(stmts.first).to include("current_user_id")
      expect(connection.executed_sql).to be_empty
    end
  end
end
