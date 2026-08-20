# frozen_string_literal: true

require "active_record"
require "securerandom"

# THE AUDIT SEAM (K-828, Phil 2026-08-20 — the reversal of T-088/K-791).
#
# Kiosk no longer stores an audit trail; it OFFERS one. `c.audit_sink` receives
# one {Kiosk::Server::ActionEvent} per action invocation, success and failure
# alike, with the arguments IN FULL, and what happens to them is the
# operator's. Four properties carry that promise and each is asserted here:
#
#   1. with no sink configured, nothing is emitted and no event is even built;
#   2. an invocation emits exactly one event, arguments intact;
#   3. a FAILED invocation emits one too, with the error;
#   4. a sink that RAISES does not fail the action.
#
# (4) is the one that would be easy to get wrong and impossible to notice, so
# it is asserted three ways: through {AuditSink.emit} directly, through a real
# {Executor} run whose Result must still come back, and with a logger that
# raises on top of the sink that raised.
RSpec.describe Kiosk::Server::AuditSink do
  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity }
  let(:events)     { [] }
  let(:sink)       { ->(event) { events << event } }

  # ── the value object ────────────────────────────────────────────────────

  describe Kiosk::Server::ActionEvent do
    subject(:event) do
      described_class.build(identity: identity, name: "place_order",
                            args: { sku: "ABC", qty: 2, express: true },
                            status: described_class::OK, invoked_at: invoked_at)
    end

    let(:invoked_at) { Time.now - 5 }

    it "carries every fact the retired action_log columns carried" do
      expect(event.to_h).to eq(
        action:        "place_order",
        user_id:       "u-1",
        agent_id:      "a-1",
        role:          "customer",
        actor:         "agent",
        args:          { sku: "ABC", qty: 2, express: true },
        status:        "ok",
        error_class:   nil,
        error_message: nil,
        invoked_at:    invoked_at,
      )
    end

    it "hands the arguments over IN FULL — values included, nothing withheld" do
      expect(event.args[:sku]).to eq("ABC")
      expect(event.args.keys).to contain_exactly(:sku, :qty, :express)
    end

    it "carries the error class and an UNTRUNCATED message on the failure branch" do
      long  = "x" * 5_000
      failed = described_class.build(identity: identity, name: "place_order", args: {},
                                     status: described_class::ERROR,
                                     error: ArgumentError.new(long))

      expect(failed).to be_error
      expect(failed.error_class).to eq("ArgumentError")
      expect(failed.error_message.length).to eq(5_000)
    end

    it "keeps a role-less principal's role nil — there is no column to satisfy" do
      service = described_class.build(
        identity: build_identity(actor: "service", role: nil, agent_id: nil),
        name: "place_order", args: {}, status: described_class::OK,
      )

      expect(service.role).to be_nil
      expect(service.actor).to eq("service")
      expect(service.agent_id).to be_nil
    end

    describe "the redaction helpers — easy, obvious, and the operator's choice" do
      it "#arg_types names each argument and its JSON type, never its value" do
        expect(event.arg_types)
          .to eq("sku" => "string", "qty" => "integer", "express" => "boolean")
      end

      it "#arg_types speaks the vocabulary input_schema declares in" do
        typed = described_class.build(identity: identity, name: "x", status: described_class::OK,
                                      args: { a: nil, b: 1.5, c: [1], d: { x: 1 } })

        expect(typed.arg_types)
          .to eq("a" => "null", "b" => "number", "c" => "array", "d" => "object")
      end

      it "#with_arg_types returns the same event with the values gone" do
        redacted = event.with_arg_types

        expect(redacted.args).to eq(event.arg_types)
        expect(redacted.to_h.except(:args)).to eq(event.to_h.except(:args))
        expect(redacted.to_h.to_s).not_to include("ABC")
      end

      it "#without_args drops them entirely" do
        expect(event.without_args.args).to eq({})
      end
    end
  end

  # ── the configuration seam ──────────────────────────────────────────────

  describe "Kiosk.configuration.audit_sink" do
    it "is nil by default — Kiosk emits nothing until an operator asks" do
      expect(Kiosk.configuration.audit_sink).to be_nil
      expect(described_class).not_to be_configured
    end

    it "takes a lambda" do
      Kiosk.configure { |c| c.audit_sink = sink }

      expect(described_class).to be_configured
    end

    it "takes any object that answers #call — a stateful sink of the operator's" do
      stateful = Class.new { def call(event) = event }.new
      Kiosk.configure { |c| c.audit_sink = stateful }

      expect(Kiosk.configuration.audit_sink).to be(stateful)
    end

    it "rejects a non-callable AT CONFIGURE TIME, not as a silent missing trail" do
      expect { Kiosk.configure { |c| c.audit_sink = "AuditLog" } }
        .to raise_error(ArgumentError, /audit_sink must be callable/)
    end

    it "takes nil back, to turn emission off again" do
      Kiosk.configure { |c| c.audit_sink = sink }
      Kiosk.configure { |c| c.audit_sink = nil }

      expect(described_class).not_to be_configured
    end
  end

  # ── emission, and the guarantee ─────────────────────────────────────────

  describe ".emit" do
    let(:event) do
      Kiosk::Server::ActionEvent.build(identity: identity, name: "place_order",
                                       args: { sku: "ABC" },
                                       status: Kiosk::Server::ActionEvent::OK)
    end

    it "hands the event to the configured sink" do
      Kiosk.configure { |c| c.audit_sink = sink }

      expect(described_class.emit(event)).to be(true)
      expect(events).to eq([event])
    end

    it "does nothing and reports nothing when no sink is configured" do
      expect(described_class.emit(event)).to be(false)
      expect(events).to be_empty
    end

    it "SWALLOWS a raising sink, reports it, and returns false" do
      Kiosk.configure { |c| c.audit_sink = ->(_e) { raise "kafka is down" } }

      expect { expect(described_class.emit(event)).to be(false) }
        .to output(/audit_sink raised for action "place_order".*kafka is down/).to_stderr
    end

    it "survives a sink that raises AND a reporter that raises" do
      Kiosk.configure { |c| c.audit_sink = ->(_e) { raise "kafka is down" } }
      allow(described_class).to receive(:warn).and_raise(IOError, "stderr is gone")

      expect { described_class.emit(event) }.not_to raise_error
    end

    it "swallows a sink that is not callable after all (assigned around the writer)" do
      Kiosk.configuration.instance_variable_set(:@audit_sink, "not a lambda")

      expect { expect(described_class.emit(event)).to be(false) }
        .to output(/audit_sink raised/).to_stderr
    end

    it "does NOT swallow a non-StandardError — that is the process dying, not a log bug" do
      fatal = Class.new(Exception) # deliberately NOT a StandardError
      Kiosk.configure { |c| c.audit_sink = ->(_e) { raise fatal, "out of memory" } }

      expect { described_class.emit(event) }.to raise_error(fatal)
    end
  end

  # ── the Executor seam: one event per action invocation ──────────────────

  describe "one event per action invocation (through Kiosk::Server::Executor)" do
    def run!(name: "place_order", args: { sku: "ABC", slot: "2026-06-15T14:00:00Z" })
      Kiosk::Server::Executor.call(kind: :run, args: args, name: name,
                                   identity: identity, connection: connection)
    end

    context "with a sink configured" do
      before { Kiosk.configure { |c| c.audit_sink = sink } }

      it "emits exactly one event, with the arguments the assistant actually sent" do
        declare_action("place_order") { render json: { id: 7 } }
        run!

        expect(events.size).to eq(1)
        expect(events.first).to be_ok
        expect(events.first.action).to eq("place_order")
        expect(events.first.agent_id).to eq("a-1")
        expect(events.first.args).to eq(sku: "ABC", slot: "2026-06-15T14:00:00Z")
        expect(events.first.invoked_at).to be_within(60).of(Time.now)
      end

      it "emits for a FAILED action too, carrying the error, and re-raises untouched" do
        declare_action("place_order") { raise "inventory exploded" }

        expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)

        expect(events.size).to eq(1)
        expect(events.first).to be_error
        expect(events.first.error_class).to eq("Kiosk::Server::Errors::ActionFailed")
        expect(events.first.error_message).to include("inventory exploded")
        expect(events.first.args).to eq(sku: "ABC", slot: "2026-06-15T14:00:00Z")
      end

      it "symbolizes the wire's string keys, as the handler sees them" do
        declare_action("place_order") { render json: {} }
        run!(args: { "sku" => "ABC", "qty" => 2 })

        expect(events.first.args).to eq(sku: "ABC", qty: 2)
      end

      it "emits NOTHING for a query — this is an action trail, not a request log" do
        declare_query("catalog") { render json: [] }
        Kiosk::Server::Executor.call(kind: :query, args: {}, name: "catalog",
                                     identity: identity, connection: connection)

        expect(events).to be_empty
      end

      it "emits NOTHING for a name no registry knows — nothing was invoked" do
        expect { run!(name: "no_such_action") }
          .to raise_error(Kiosk::Server::Errors::NotFound)

        expect(events).to be_empty
      end

      it "WRITES NOTHING TO ANY TABLE — the trail left the database with K-828" do
        declare_action("place_order") { render json: {} }
        run!

        expect(connection.all_sql).not_to include("action_log")
        expect(connection.all_sql).not_to match(/INSERT INTO kiosk\.actions/)
      end

      it "emits OUTSIDE the action's transaction — a sink cannot hold it open" do
        declare_action("place_order") { render json: {} }
        depths = []
        Kiosk.configure { |c| c.audit_sink = ->(_e) { depths << connection.in_transaction? } }
        run!

        expect(depths).to eq([false])
      end
    end

    context "with a sink that raises" do
      before { Kiosk.configure { |c| c.audit_sink = ->(_e) { raise "kafka is down" } } }

      it "still returns the action's result — the operator's logging bug is theirs" do
        declare_action("place_order") { render json: { id: 7 } }

        result = nil
        expect { result = run! }.to output(/audit_sink raised/).to_stderr
        expect(result.payload).to eq("id" => 7)
      end

      it "still raises the ACTION's error, not the sink's, on the failure branch" do
        declare_action("place_order") { raise "inventory exploded" }

        expect { run! }
          .to raise_error(Kiosk::Server::Errors::ActionFailed, /inventory exploded/)
          .and output(/audit_sink raised/).to_stderr
      end
    end

    context "with NO sink configured (the default)" do
      it "emits nothing and does not even build an event" do
        declare_action("place_order") { render json: { id: 7 } }
        expect(Kiosk::Server::ActionEvent).not_to receive(:build)

        expect(run!.payload).to eq("id" => 7)
        expect(events).to be_empty
      end

      it "writes nothing to any table on the failure branch either" do
        declare_action("place_order") { raise "inventory exploded" }

        expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)
        expect(connection.all_sql).not_to include("action_log")
      end
    end
  end

  # ── against a real Postgres: the emission survives a real ROLLBACK ──────
  #
  # The one property no fake can establish. A failed action's SessionContext
  # really rolls back — the row it wrote is gone — and the event must have been
  # emitted anyway, which is why the seam sits outside the transaction rather
  # than inside it. Connection from PG* env vars (CI's service) or the local
  # default socket; no reachable server → skip, never fail (the same contract
  # as `executor_persistence_spec.rb`).
  describe "a real invocation against a real database" do
    SINK_SPEC_SCHEMA = "kiosk_audit_sink_spec"

    def self.postgres_error
      @postgres_error ||= begin
        ::ActiveRecord::Base.establish_connection(
          adapter:  "postgresql",
          host:     ENV["PGHOST"],
          username: ENV["PGUSER"],
          password: ENV["PGPASSWORD"],
          database: ENV.fetch("PGDATABASE", "postgres"),
        )
        ::ActiveRecord::Base.connection.execute("SELECT 1")
        [false]
      rescue StandardError => e
        ["#{e.class}: #{e.message}"]
      end
      @postgres_error.first
    end

    before(:context) do
      skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error

      conn = ::ActiveRecord::Base.connection
      conn.execute(%(DROP SCHEMA IF EXISTS "#{SINK_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{SINK_SPEC_SCHEMA}"))
      conn.execute(%(CREATE TABLE "#{SINK_SPEC_SCHEMA}".widgets (id serial primary key)))
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{SINK_SPEC_SCHEMA}" CASCADE))
      end
    end

    let(:connection) { ::ActiveRecord::Base.connection }

    before do
      Kiosk.configure do |c|
        c.schema     = SINK_SPEC_SCHEMA
        c.audit_sink = sink
      end
      connection.execute(%(TRUNCATE "#{SINK_SPEC_SCHEMA}".widgets))
    end

    def widget_count
      connection.exec_query(%(SELECT COUNT(*) AS n FROM "#{SINK_SPEC_SCHEMA}".widgets))
                .to_a.first["n"]
    end

    it "emits the event even though the action's own write rolled back" do
      declare_action("place_order") do
        ActiveRecord::Base.connection.execute(%(INSERT INTO "#{SINK_SPEC_SCHEMA}".widgets DEFAULT VALUES))
        raise "too late"
      end

      expect {
        Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                     identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed)

      expect(widget_count).to eq(0)  # the action really rolled back …
      expect(events.size).to eq(1)   # … and the event was emitted anyway
      expect(events.first).to be_error
    end

    it "commits a successful action and emits exactly one event for it" do
      declare_action("place_order") do
        ActiveRecord::Base.connection.execute(%(INSERT INTO "#{SINK_SPEC_SCHEMA}".widgets DEFAULT VALUES))
        render json: {}
      end

      Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                   identity: identity, connection: connection)

      expect(widget_count).to eq(1)
      expect(events.size).to eq(1)
      expect(events.first.args).to eq(sku: "ABC")
    end

    it "leaves the action committed when the SINK is the thing that raises" do
      Kiosk.configure { |c| c.audit_sink = ->(_e) { raise "kafka is down" } }
      declare_action("place_order") do
        ActiveRecord::Base.connection.execute(%(INSERT INTO "#{SINK_SPEC_SCHEMA}".widgets DEFAULT VALUES))
        render json: {}
      end

      expect {
        Kiosk::Server::Executor.call(kind: :run, args: {}, name: "place_order",
                                     identity: identity, connection: connection)
      }.to output(/audit_sink raised/).to_stderr

      expect(widget_count).to eq(1)
    end
  end
end
