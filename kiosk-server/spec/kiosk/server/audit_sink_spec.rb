# frozen_string_literal: true

require "active_record"
require "securerandom"

# THE AUDIT SEAM (K-828, 2026-08-20 — the reversal of T-088/K-791).
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
        cause_class:   nil,
        cause_message: nil,
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

    # WHAT THE NAME ABOVE PROMISES, THROUGH THE PATH THAT ACTUALLY EMITS
    # (K-1311). The arm above hands `build` a bare exception; the Executor
    # hands it the WRAPPER, because since K-1307 the handler's own sentence is
    # not the wire's to publish. That is right for the wire and wrong for a
    # sink — operator-side, in the operator's own process, already holding the
    # arguments in full — so the wrapped exception travels beside the wrapper
    # rather than instead of it.
    describe "a wrapped handler failure, which is what the Executor emits" do
      let(:wrapped) do
        long = "y" * 5_000
        error =
          begin
            begin
              raise ArgumentError, long
            rescue ArgumentError
              raise Kiosk::Server::Errors::ActionFailed.new(
                'Action "place_order" raised ArgumentError',
                hint: "See server logs for the backtrace.",
              )
            end
          rescue Kiosk::Server::Errors::ActionFailed => e
            e
          end
        described_class.build(identity: identity, name: "place_order", args: {},
                              status: described_class::ERROR, error: error)
      end

      it "still names what the WIRE refused with — a sink alerting on it keeps meaning it" do
        expect(wrapped.error_class).to eq("Kiosk::Server::Errors::ActionFailed")
        expect(wrapped.error_message).to eq('Action "place_order" raised ArgumentError')
      end

      it "carries the handler's OWN class and its UNTRUNCATED message as the cause" do
        expect(wrapped.cause_class).to eq("ArgumentError")
        expect(wrapped.cause_message.length).to eq(5_000)
      end

      it "leaves the pair nil when the raise wraps nothing, rather than inventing one" do
        bare = described_class.build(identity: identity, name: "place_order", args: {},
                                     status: described_class::ERROR, error: ArgumentError.new("x"))
        expect(bare.cause_class).to be_nil
        expect(bare.cause_message).to be_nil
      end

      it "never reports an exception as its own cause" do
        selfish = Class.new(StandardError) do
          def cause = self
        end.new("loop")
        built = described_class.build(identity: identity, name: "place_order", args: {},
                                      status: described_class::ERROR, error: selfish)
        expect(built.cause_class).to be_nil
      end
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

      # WHAT THE EVENT CARRIES SINCE K-1307, and why this example inverted.
      #
      # The event is built from the exception that ESCAPED the invocation, and
      # that is the wire error — so it carries what the wire carries: the verb,
      # the exception CLASS, and none of the handler's own sentence. This
      # example used to assert `include("inventory exploded")`, i.e. it pinned
      # the handler's arbitrary Ruby message into the refusal an unauthenticated
      # caller can read back. The sentence is not lost: `Executor` reports it
      # operator-side before it re-raises, which the stderr expectation below
      # asserts in the same breath, so a reader can see both halves of the
      # split in one example.
      #
      # AND SINCE K-1311 IT IS NOT LOST TO THE SINK EITHER. The split above was
      # about the WIRE; a sink is the operator's own process and there is
      # nothing there to protect it from, so the wrapped exception rides along
      # as `cause_class`/`cause_message` — beside the wire error, never in
      # place of it.
      it "emits for a FAILED action too, carrying the WIRE error, and re-raises untouched" do
        declare_action("place_order") { raise "inventory exploded" }

        expect {
          expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)
        }.to output(/\[kiosk-server\] Action "place_order" raised RuntimeError: inventory exploded/)
          .to_stderr

        expect(events.size).to eq(1)
        expect(events.first).to be_error
        expect(events.first.error_class).to eq("Kiosk::Server::Errors::ActionFailed")
        expect(events.first.error_message).to eq('Action "place_order" raised RuntimeError')
        expect(events.first.error_message).not_to include("inventory exploded")
        expect(events.first.args).to eq(sku: "ABC", slot: "2026-06-15T14:00:00Z")
      end

      it "…and hands the sink the handler's OWN error as the cause (K-1311)" do
        declare_action("place_order") { raise "inventory exploded" }

        expect {
          expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)
        }.to output(/inventory exploded/).to_stderr

        expect(events.first.cause_class).to eq("RuntimeError")
        expect(events.first.cause_message).to eq("inventory exploded")
      end

      # THE SECOND FAILURE ROUTE, and the one that needed threading rather than
      # reading. A raise Rails knows a status for is mapped by the mixin's
      # `rescue_from` seam, which RENDERS — so the wire error is rebuilt by
      # HandlerDispatch in a frame where nothing is being rescued, and Ruby
      # attaches no `cause` of its own. Without the hand-off the sink would see
      # only `verb "…" rejected the request as malformed`, which names nothing
      # an operator can act on. Measured on the e2e harness before the hand-off
      # existed: a failing booking's event carried no cause at all.
      it "carries the cause through the rescue_from seam too, which renders rather than raises" do
        declare_action("place_order") { raise ArgumentError, "salon must exist" }
        ActionDispatch::ExceptionWrapper.rescue_responses["ArgumentError"] = :unprocessable_entity

        expect { run! }.to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("bad_request")
          expect(e.message).not_to include("salon must exist")
        }

        expect(events.first.error_class).to eq("Kiosk::Server::Errors::WireError")
        expect(events.first.cause_class).to eq("ArgumentError")
        expect(events.first.cause_message).to eq("salon must exist")
      ensure
        ActionDispatch::ExceptionWrapper.rescue_responses.delete("ArgumentError")
      end

      it "leaves the cause pair nil for a refusal the handler MEANT — nothing is wrapped" do
        declare_action("place_order") do
          raise Kiosk::Server::Errors::Forbidden.new("assistants may not do that",
                                                     hint: "ask your human")
        end

        expect { run! }.to raise_error(Kiosk::Server::Errors::Forbidden)

        expect(events.first.error_class).to eq("Kiosk::Server::Errors::Forbidden")
        expect(events.first.error_message).to eq("assistants may not do that")
        expect(events.first.cause_class).to be_nil
        expect(events.first.cause_message).to be_nil
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
          .to raise_error(Kiosk::Server::Errors::VerbNotFound)

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

      # The discriminator used to be `/inventory exploded/` — the ACTION's
      # words as against the SINK's "kafka is down" — and it worked only for
      # as long as the wire carried the splice (K-1307). It is now the wire
      # sentence itself, with BOTH foreign messages asserted absent from it and
      # both present on the operator's stderr, in the order they are reported:
      # the handler's crash from inside `verb_run`, the sink's from the audit
      # seam that wraps it.
      it "still raises the ACTION's error, not the sink's, on the failure branch" do
        declare_action("place_order") { raise "inventory exploded" }

        expect {
          expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed) { |e|
            expect(e.message).to eq('Action "place_order" raised RuntimeError')
            expect(e.message).not_to include("inventory exploded")
            expect(e.message).not_to include("kafka is down")
          }
        }.to output(/raised RuntimeError: inventory exploded/).to_stderr
      end

      it "reports BOTH failures to the operator — the handler's and the sink's" do
        declare_action("place_order") { raise "inventory exploded" }

        expect {
          expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)
        }.to output(
          %r{Action "place_order" raised RuntimeError: inventory exploded.*audit_sink raised for action "place_order": RuntimeError: kafka is down}m,
        ).to_stderr
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

        # The stderr expectation is not decoration: `Executor` reports the
        # handler's crash to the operator whether or not a sink is configured
        # (K-1307), and leaving it uncaptured would spatter a backtrace across
        # this suite's output for a property this example is not about.
        expect {
          expect { run! }.to raise_error(Kiosk::Server::Errors::ActionFailed)
        }.to output(/raised RuntimeError: inventory exploded/).to_stderr

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
        expect {
          Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                       identity: identity, connection: connection)
        }.to raise_error(Kiosk::Server::Errors::ActionFailed)
      }.to output(/raised RuntimeError: too late/).to_stderr

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
