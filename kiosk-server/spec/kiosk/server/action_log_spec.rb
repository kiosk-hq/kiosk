# frozen_string_literal: true

require "active_record"
require "securerandom"

# THE AUDIT LOG (T-088 / K-791).
#
# Two halves, and the second is the one the T-088 row demands: a READ-BACK
# proving a real invocation lands a real row, and the FAILURE branch proving a
# raised action lands one too. Neither can be asserted against a fake — the
# `action_name` FK, the `jsonb` cast, the NOT NULLs and the fact that a failed
# action's ROLLBACK must NOT take the log row with it are all properties of
# Postgres, not of the Ruby. So the write path is exercised twice: once through
# `FakeConnection` for the statement shape and the redaction policy, and once
# through `Kiosk::Server::Executor.call` against a real database with the
# SHIPPED migration SQL.
#
# Connection from PG* env vars (CI's service) or the local default socket; no
# reachable server → skip, never fail, so DB-less machines stay green (the same
# contract as `executor_persistence_spec.rb`).
RSpec.describe Kiosk::Server::ActionLog do
  # ── the statement shape + the policies (no database) ────────────────────

  describe ".redact" do
    let(:args) { { "salon_id" => 3, "slot" => "2026-06-15T14:00:00Z", "vip" => true } }

    it "records argument NAMES and JSON TYPES by default, never the values" do
      redacted = described_class.redact(args)

      expect(redacted).to eq("salon_id" => "integer", "slot" => "string", "vip" => "boolean")
      expect(redacted.values).not_to include("2026-06-15T14:00:00Z")
    end

    it "names every JSON type in the vocabulary input_schema uses" do
      expect(described_class.redact({ a: nil, b: 1.5, c: [1], d: { x: 1 } }))
        .to eq("a" => "null", "b" => "number", "c" => "array", "d" => "object")
    end

    it "records nothing at all under :none" do
      expect(described_class.redact(args, policy: :none)).to eq({})
    end

    it "records them verbatim under :full — the operator's explicit call" do
      expect(described_class.redact(args, policy: :full)).to eq(args)
    end

    it "hands the arguments to a callable policy and stores what it returns" do
      policy = ->(a) { { "salon_id" => a["salon_id"] } }

      expect(described_class.redact(args, policy: policy)).to eq("salon_id" => 3)
    end

    it "refuses an unknown policy by name" do
      expect { described_class.redact(args, policy: :verbatim) }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /audit_log_args/)
    end
  end

  describe ".loggable?" do
    it "is false for a name no registry knows — the FK could not be satisfied" do
      expect(described_class.loggable?("nope")).to be(false)
    end

    it "is true for a registered action" do
      declare_action("place_order")

      expect(described_class.loggable?("place_order")).to be(true)
    end

    it "is false for a QUERY name: queries are not logged" do
      declare_query("catalog")

      expect(described_class.loggable?("catalog")).to be(false)
    end

    it "is false when the operator turned the audit log off" do
      declare_action("place_order")
      Kiosk.configure { |c| c.audit_log = false }

      expect(described_class.loggable?("place_order")).to be(false)
    end

    it "is false for a blank name" do
      expect(described_class.loggable?(nil)).to be(false)
      expect(described_class.loggable?("")).to be(false)
    end
  end

  describe ".record statement shape" do
    let(:connection) { FakeConnection.new }
    let(:identity)   { build_identity }

    before { declare_action("place_order", description: "places an order") }

    def record!(**overrides)
      described_class.record(
        connection: connection, identity: identity, name: "place_order",
        args: { sku: "ABC" }, status: described_class::OK, **overrides
      )
    end

    it "upserts the FK anchor and inserts the row, both with BIND PARAMETERS" do
      expect(record!).to be(true)

      anchor = connection.bound(/INSERT INTO kiosk\.actions/).first
      expect(anchor.last).to eq(["place_order", "places an order"])

      sql, binds = connection.bound(/INSERT INTO kiosk\.action_log/).first
      expect(sql).to include("$6::jsonb")
      expect(binds[0, 5]).to eq(["place_order", "u-1", "a-1", "customer", "agent"])
      expect(JSON.parse(binds[5])).to eq("sku" => "string")
      expect(binds[6]).to eq("ok")
      expect(binds[7, 2]).to eq([nil, nil])
    end

    it "never splices a value into the statement text and never calls #quote" do
      expect(connection).not_to receive(:quote)
      record!(args: { sku: "SPLICE-ME" })

      expect(connection.all_sql).not_to include("SPLICE-ME")
      expect(connection.all_sql).not_to include("u-1")
    end

    it "records the error class and a truncated message on the failure branch" do
      record!(status: described_class::ERROR,
              error: ArgumentError.new("x" * (described_class::MAX_ERROR_MESSAGE + 50)))

      binds = connection.bound(/INSERT INTO kiosk\.action_log/).first.last
      expect(binds[6]).to eq("error")
      expect(binds[7]).to eq("ArgumentError")
      expect(binds[8].length).to eq(described_class::MAX_ERROR_MESSAGE + 1)
      expect(binds[8]).to end_with("…")
    end

    it "writes the empty-string sentinel for a role-less principal" do
      record!(identity: build_identity(actor: "service", role: nil, agent_id: nil))

      binds = connection.bound(/INSERT INTO kiosk\.action_log/).first.last
      expect(binds[3]).to eq(described_class::NO_ROLE)
      expect(binds[4]).to eq("service")
    end

    it "opens NO SessionContext — no GUCs, no SET LOCAL ROLE (outside RLS)" do
      Kiosk.configure { |c| c.enforce_db_role = true }
      record!

      expect(connection.all_sql).not_to include("set_config")
      expect(connection.all_sql).not_to include("SET LOCAL ROLE")
    end

    it "reports a failed write and returns false — it never raises at the caller" do
      allow(connection).to receive(:transaction).and_raise(RuntimeError, "table is gone")

      expect { expect(record!).to be(false) }
        .to output(/audit log write failed for action "place_order".*table is gone/).to_stderr
    end
  end

  # ── the read-back, against a real Postgres ──────────────────────────────

  describe "a real invocation lands a real row (real Postgres)" do
    LOG_SPEC_SCHEMA = "kiosk_action_log_spec"

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
      conn.execute(%(DROP SCHEMA IF EXISTS "#{LOG_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{LOG_SPEC_SCHEMA}"))
      # The SHIPPED migration SQL, not a hand-written table: the whole point is
      # that the writer agrees with the schema every adopter installs — the FK,
      # the NOT NULLs and the jsonb column included.
      conn.execute(
        Kiosk::Server::SchemaDefinitions.actions_log_sql(
          schema: LOG_SPEC_SCHEMA, user_id_type: :text,
        ),
      )
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{LOG_SPEC_SCHEMA}" CASCADE))
      end
    end

    let(:connection) { ::ActiveRecord::Base.connection }
    let(:agent_uuid) { SecureRandom.uuid }
    let(:identity)   { build_identity(user_id: "u-#{SecureRandom.hex(4)}", agent_id: agent_uuid) }

    before do
      Kiosk.configure { |c| c.schema = LOG_SPEC_SCHEMA }
      connection.execute(%(TRUNCATE "#{LOG_SPEC_SCHEMA}".action_log))
    end

    def rows = described_class.recent(connection: connection, user_id: identity.user_id)

    it "writes one row per invocation, read back through the operator-side reader" do
      declare_action("place_order", description: "places an order") { render json: { id: 7 } }

      Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC", qty: 2 }, name: "place_order",
                                   identity: identity, connection: connection)

      expect(rows.size).to eq(1)
      row = rows.first
      expect(row["action_name"]).to eq("place_order")
      expect(row["user_id"]).to eq(identity.user_id)
      expect(row["agent_id"]).to eq(agent_uuid)
      expect(row["role"]).to eq("customer")
      expect(row["actor"]).to eq("agent")
      expect(row["result_status"]).to eq("ok")
      expect(row["error_class"]).to be_nil
      expect(row["invoked_at"]).to be_within(60).of(Time.now)
    end

    it "stored `args` as jsonb — containment matches, so it is not a json string" do
      declare_action("place_order") { render json: {} }
      Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                   identity: identity, connection: connection)

      matched = connection.exec_query(
        %(SELECT COUNT(*) AS n FROM "#{LOG_SPEC_SCHEMA}".action_log WHERE args @> '{"sku":"string"}'::jsonb),
      ).to_a.first["n"]
      expect(matched).to eq(1)
    end

    it "upserts the FK anchor into `actions`, description and all" do
      declare_action("place_order", description: "places an order") { render json: {} }
      Kiosk::Server::Executor.call(kind: :run, args: {}, name: "place_order",
                                   identity: identity, connection: connection)

      registered = connection.exec_query(
        %(SELECT name, description FROM "#{LOG_SPEC_SCHEMA}".actions),
      ).to_a
      expect(registered).to eq([{ "name" => "place_order", "description" => "places an order" }])
    end

    # THE FAILURE BRANCH — and it is the reason the write is AFTER the
    # action's transaction rather than inside it. The handler raises, the
    # SessionContext ROLLS BACK, and the audit row must still be there.
    it "logs a FAILED action, after its own transaction rolled back" do
      declare_action("place_order") { raise "inventory exploded" }

      expect {
        Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                     identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed)

      expect(rows.size).to eq(1)
      expect(rows.first["result_status"]).to eq("error")
      expect(rows.first["error_class"]).to eq("Kiosk::Server::Errors::ActionFailed")
      expect(rows.first["error_message"]).to include("inventory exploded")
    end

    it "proves the rollback is real: the failed action's own write did NOT land" do
      connection.execute(%(CREATE TABLE IF NOT EXISTS "#{LOG_SPEC_SCHEMA}".widgets (id serial primary key)))
      connection.execute(%(TRUNCATE "#{LOG_SPEC_SCHEMA}".widgets))
      declare_action("place_order") do
        ActiveRecord::Base.connection.execute(%(INSERT INTO "#{LOG_SPEC_SCHEMA}".widgets DEFAULT VALUES))
        raise "too late"
      end

      expect {
        Kiosk::Server::Executor.call(kind: :run, args: {}, name: "place_order",
                                     identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed)

      widgets = connection.exec_query(
        %(SELECT COUNT(*) AS n FROM "#{LOG_SPEC_SCHEMA}".widgets),
      ).to_a.first["n"]
      expect(widgets).to eq(0)   # the action rolled back …
      expect(rows.size).to eq(1) # … and the audit row survived it
    end

    it "does NOT log a query — the table is an ACTION log" do
      declare_query("catalog") { render json: [] }

      Kiosk::Server::Executor.call(kind: :query, args: {}, name: "catalog",
                                   identity: identity, connection: connection)

      expect(rows).to be_empty
    end

    it "writes nothing when the operator turned the audit log off" do
      declare_action("place_order") { render json: {} }
      Kiosk.configure { |c| c.audit_log = false }

      Kiosk::Server::Executor.call(kind: :run, args: {}, name: "place_order",
                                   identity: identity, connection: connection)

      expect(rows).to be_empty
    end

    it "stores the values verbatim when the operator asks for :full" do
      declare_action("place_order") { render json: {} }
      Kiosk.configure { |c| c.audit_log_args = :full }

      Kiosk::Server::Executor.call(kind: :run, args: { sku: "ABC" }, name: "place_order",
                                   identity: identity, connection: connection)

      expect(JSON.parse(rows.first["args"])).to eq("sku" => "ABC")
    end

    it "reads back newest-first, filtered by agent, capped by limit" do
      declare_action("place_order") { render json: {} }
      3.times do
        Kiosk::Server::Executor.call(kind: :run, args: {}, name: "place_order",
                                     identity: identity, connection: connection)
      end

      expect(described_class.recent(connection: connection, agent_id: agent_uuid, limit: 2).size)
        .to eq(2)
      expect(described_class.recent(connection: connection, agent_id: SecureRandom.uuid))
        .to be_empty
    end
  end
end
