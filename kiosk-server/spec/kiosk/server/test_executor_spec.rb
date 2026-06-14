# frozen_string_literal: true

require "kiosk/server/test_executor"

RSpec.describe Kiosk::Server::TestExecutor do
  # Test connection that can pretend to be either a real AR connection
  # or an RLS-violating Postgres. FakeConnection in spec_helper.rb is
  # too minimal — we extend it here so tests can stage queued results
  # and queued errors.
  class TestableConnection
    attr_reader :executed_sql, :transactions_opened

    def initialize
      @executed_sql        = []
      @transactions_opened = 0
      @queued_results      = []
      @queued_errors       = []
    end

    def transaction
      @transactions_opened += 1
      yield
    end

    def execute(sql)
      @executed_sql << sql

      # SET LOCAL is a side-effect DDL — never returns rows and must
      # NOT consume from the queue (which is staged for the SQL under
      # test, not the housekeeping GUCs).
      return [] if sql.start_with?("SET LOCAL")

      raise @queued_errors.shift if @queued_errors.any?

      @queued_results.empty? ? [] : @queued_results.shift
    end

    # Test rig:
    def queue_result(rows)         = @queued_results << rows
    def queue_error(klass, msg)    = @queued_errors  << klass.new(msg)
  end

  let(:connection)        { TestableConnection.new }
  let(:system_connection) { TestableConnection.new }
  let(:executor)          { described_class.new(connection: connection, system_connection: system_connection) }
  let(:identity)          { build_identity(actor: "agent") }

  describe "#with_identity" do
    it "opens exactly one transaction" do
      executor.with_identity(identity) { :inside }
      expect(connection.transactions_opened).to eq(1)
    end

    it "sets the four canonical GUCs before yielding" do
      executor.with_identity(identity) { :inside }
      gucs = connection.executed_sql.select { |s| s.start_with?("SET LOCAL") }
      expect(gucs.size).to eq(4)
      expect(gucs.map { |s| s[/"app"\."(\w+)"/, 1] })
        .to match_array(%w[current_user_id current_role current_actor current_agent_id])
    end

    it "exposes the identity inside the block (#current_identity)" do
      observed = nil
      executor.with_identity(identity) { observed = executor.current_identity }
      expect(observed).to eq(identity)
    end

    it "clears identity after the block returns" do
      executor.with_identity(identity) { :inside }
      expect(executor.current_identity).to be_nil
    end

    it "rolls back unconditionally by raising the marker (always swallowed)" do
      expect { executor.with_identity(identity) { :inside } }.not_to raise_error
    end

    it "returns the block's last value" do
      value = executor.with_identity(identity) { 42 }
      expect(value).to eq(42)
    end

    it "propagates a block exception after the rollback" do
      expect {
        executor.with_identity(identity) { raise "boom" }
      }.to raise_error(RuntimeError, "boom")
      # Identity was still cleaned up even after the raise.
      expect(executor.current_identity).to be_nil
    end

    it "skips GUC setup when identity is nil (as_anonymous semantics)" do
      executor.with_identity(nil) { :inside }
      expect(connection.executed_sql.select { |s| s.start_with?("SET LOCAL") }).to be_empty
    end

    it "requires a block" do
      expect { executor.with_identity(identity) }.to raise_error(ArgumentError, /block required/)
    end

    it "marks in_scope? for the duration of the block" do
      seen = false
      executor.with_identity(identity) { seen = executor.in_scope? }
      expect(seen).to be(true)
      expect(executor.in_scope?).to be(false)
    end
  end

  describe "#query (default-deny enforcement)" do
    it "raises NoScopeError when called outside any with_identity scope" do
      expect { executor.query("SELECT 1") }
        .to raise_error(described_class::NoScopeError, /default-deny/)
    end

    it "executes the SQL through the app connection inside scope" do
      connection.queue_result([{ "n" => 1 }])
      result = executor.with_identity(identity) { executor.query("SELECT 1 AS n") }
      expect(connection.executed_sql).to include("SELECT 1 AS n")
      expect(result).to eq([{ n: 1 }])
    end

    it "returns rows with symbolised keys (Journey DSL convention)" do
      connection.queue_result([{ "id" => 1, "name" => "alice" }])
      rows = executor.with_identity(identity) { executor.query("SELECT id,name FROM users") }
      expect(rows.first.keys).to all(be_a(Symbol))
    end

    it "translates RLS denial (PG message) to Kiosk::TestHelpers::Errors::RLSDenied" do
      connection.queue_error(StandardError, "ERROR: new row violates row-level security policy")
      expect {
        executor.with_identity(identity) { executor.query("INSERT INTO x DEFAULT VALUES") }
      }.to raise_error(Kiosk::TestHelpers::Errors::RLSDenied)
    end

    it "translates `permission denied for table` to RLSDenied as well" do
      connection.queue_error(StandardError, "ERROR:  permission denied for table appointments")
      expect {
        executor.with_identity(identity) { executor.query("SELECT * FROM appointments") }
      }.to raise_error(Kiosk::TestHelpers::Errors::RLSDenied)
    end

    it "lets non-RLS errors propagate unchanged" do
      connection.queue_error(ArgumentError, "syntax near 'WAT'")
      expect {
        executor.with_identity(identity) { executor.query("WAT") }
      }.to raise_error(ArgumentError, /syntax/)
    end
  end

  describe "#run_action" do
    it "raises NoScopeError outside scope" do
      expect { executor.run_action(:foo, {}) }.to raise_error(described_class::NoScopeError)
    end

    it "fetches the action from the registry and calls it with args" do
      Kiosk::Server::Actions.register(:ping) { |args| { pong: args[:msg] } }
      result = executor.with_identity(identity) { executor.run_action(:ping, msg: "hi") }
      expect(result).to eq(pong: "hi")
    end

    it "raises Errors::NotFound for an unregistered action (via Actions.fetch)" do
      expect {
        executor.with_identity(identity) { executor.run_action(:missing, {}) }
      }.to raise_error(Kiosk::Server::Errors::NotFound)
    end
  end

  describe "#pay_action" do
    it "raises NotImplementedError (lands with kiosk-pay-* in M4)" do
      expect {
        executor.with_identity(identity) { executor.pay_action(:foo, {}) }
      }.to raise_error(NotImplementedError, /M4/)
    end
  end

  describe "#seed" do
    let(:row) { { "id" => 42, "user_id" => "u-1", "salon_id" => 1 } }

    it "uses the system connection (RLS bypass)" do
      system_connection.queue_result([row])
      executor.seed(:appointments, { user_id: "u-1", salon_id: 1 }, count: 1)
      expect(system_connection.executed_sql).not_to be_empty
      expect(connection.executed_sql).to be_empty
    end

    it "issues `count` INSERTs with RETURNING *" do
      3.times { system_connection.queue_result([row]) }
      executor.seed(:appointments, { user_id: "u-1", salon_id: 1 }, count: 3)
      inserts = system_connection.executed_sql.select { |s| s.start_with?("INSERT INTO") }
      expect(inserts.size).to eq(3)
      expect(inserts.first).to include("RETURNING *")
    end

    it "quotes column names + table to defang reserved words / casing" do
      system_connection.queue_result([row])
      executor.seed("public.events", { kind: "click" }, count: 1)
      expect(system_connection.executed_sql.first).to include(%("public"."events"))
      expect(system_connection.executed_sql.first).to include(%("kind"))
    end

    it "quotes string values with single-quote escape" do
      system_connection.queue_result([row])
      executor.seed(:notes, { body: "alice's note" }, count: 1)
      expect(system_connection.executed_sql.first).to include("'alice''s note'")
    end

    it "renders numeric values without quotes" do
      system_connection.queue_result([row])
      executor.seed(:t, { amount_cents: 5_000 }, count: 1)
      expect(system_connection.executed_sql.first).to include("VALUES (5000)")
    end

    it "renders NULL for nil and TRUE/FALSE for booleans" do
      system_connection.queue_result([row])
      executor.seed(:t, { archived: false, deleted_at: nil }, count: 1)
      sql = system_connection.executed_sql.first
      expect(sql).to include("FALSE")
      expect(sql).to include("NULL")
    end

    it "returns the inserted rows with symbol keys" do
      system_connection.queue_result([row])
      result = executor.seed(:appointments, { user_id: "u-1", salon_id: 1 }, count: 1)
      expect(result.first).to include(id: 42, user_id: "u-1", salon_id: 1)
    end
  end
end
