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

    # K-789: the GUC name AND the GUC value are bind parameters. The statement
    # text is one frozen constant for all four, which is the property that
    # makes a forgotten escape impossible rather than merely absent — so these
    # assert on the BINDS, and on the text staying free of every value.
    it "sets all four GUCs through set_config binds (agent path)" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "agent", user_id: "u-1", role: "customer", agent_id: "a-1"),
      ) { }

      expect(connection.bound(/set_config/)).to eq([
        ["SELECT set_config($1, $2, true)", ["app.current_user_id",  "u-1"]],
        ["SELECT set_config($1, $2, true)", ["app.current_role",     "customer"]],
        ["SELECT set_config($1, $2, true)", ["app.current_actor",    "agent"]],
        ["SELECT set_config($1, $2, true)", ["app.current_agent_id", "a-1"]],
      ])
      # Nothing reaches the connection through `#execute` any more.
      expect(connection.executed_sql).to be_empty
    end

    it "skips the agent_id GUC for human/service actors (agent_id nil)" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "human", agent_id: nil),
      ) { }

      expect(connection.bound(/set_config/).map { |_sql, binds| binds.first })
        .to eq(%w[app.current_user_id app.current_role app.current_actor])
    end

    it "skips the role GUC for a role-less identity" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "agent", role: nil),
      ) { }

      expect(connection.bound(/set_config/).map { |_sql, binds| binds.first })
        .to eq(%w[app.current_user_id app.current_actor app.current_agent_id])
    end

    it "uses the configured GUC namespace" do
      Kiosk.configure { |c| c.guc_namespace = "kiosk" }
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "agent"),
      ) { }

      expect(connection.bound(/set_config/).first.last).to eq(["kiosk.current_user_id", "u-1"])
    end

    # The shape that used to end a spliced literal early is now a value that
    # needs no escaping at all — nothing is spliced, so nothing can be closed.
    it "passes a quote-bearing identity value straight through as a bind" do
      described_class.open(
        connection: connection,
        identity:   build_identity(actor: "human", agent_id: nil, user_id: "it's-u"),
      ) { }

      expect(connection.bound(/set_config/).first.last).to eq(["app.current_user_id", "it's-u"])
      expect(connection.all_sql).not_to include("it's-u")
    end
  end

  describe "#guc_statements" do
    it "returns [sql, binds] pairs without executing" do
      ctx = described_class.new(connection: connection, identity: build_identity(actor: "agent"))
      stmts = ctx.guc_statements

      expect(stmts.size).to eq(4)
      expect(stmts.first).to eq(["SELECT set_config($1, $2, true)", ["app.current_user_id", "u-1"]])
      expect(connection.executed_sql).to be_empty
      expect(connection.exec_queries).to be_empty
    end
  end

  describe "#guc_statements enforce_db_role" do
    before { Kiosk.reset! }

    context "when enforce_db_role is unset (default false)" do
      it "contains no SET LOCAL ROLE statement — exactly the 4 GUC statements as today" do
        ctx = described_class.new(connection: connection, identity: build_identity(actor: "agent"))
        stmts = ctx.guc_statements

        expect(stmts.size).to eq(4)
        expect(stmts.none? { |sql, _binds| sql.include?("ROLE") }).to be(true)
      end
    end

    context "when enforce_db_role is true and app_role is 'kiosk_app'" do
      before do
        Kiosk.configure do |c|
          c.enforce_db_role = true
          c.app_role        = "kiosk_app"
        end
      end

      # The role is an IDENTIFIER, which no bind can carry — so this one
      # statement keeps `quote_ident` and carries no binds at all.
      it "appends SET LOCAL ROLE as the last element, after the GUC statements" do
        ctx = described_class.new(connection: connection, identity: build_identity(actor: "agent"))
        stmts = ctx.guc_statements

        expect(stmts.last).to eq([%(SET LOCAL ROLE "kiosk_app"), []])
        expect(stmts[-2].last.first).to eq("app.current_agent_id")
      end
    end
  end

  # ── The equivalence claim, against a database that can disagree ──────────
  #
  # `set_config(name, value, true)` replaces `SET LOCAL name = 'value'`
  # (K-789). A fake records strings and cannot tell you whether Postgres
  # agrees, and the property at stake — the GUC is TRANSACTION-LOCAL — is
  # exactly the one that fails OPEN if it regresses: an unset
  # `app.current_user_id` makes every `kiosk.current_user_id()` predicate and
  # every RLS policy see NULL, and a leaked one makes them see the PREVIOUS
  # request's principal. Same skip contract as the other real-Postgres files.
  describe "against a real Postgres" do
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

    before { skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error }

    let(:real) { ::ActiveRecord::Base.connection }

    def current(name) = real.select_value("SELECT current_setting('#{name}', true)")

    it "lands the four GUCs on the connection the block then uses" do
      seen = {}
      described_class.open(
        connection: real,
        identity:   build_identity(actor: "agent", user_id: "u-real", role: "customer", agent_id: "a-real"),
      ) do
        %w[current_user_id current_role current_actor current_agent_id].each do |g|
          seen[g] = current("app.#{g}")
        end
      end

      expect(seen).to eq(
        "current_user_id" => "u-real", "current_role" => "customer",
        "current_actor" => "agent", "current_agent_id" => "a-real",
      )
    end

    # `true` IS `LOCAL`. If it ever stopped being, the value would survive the
    # COMMIT and the NEXT request on this pooled connection would run as the
    # previous principal.
    it "is transaction-LOCAL: the values are gone after COMMIT" do
      described_class.open(connection: real, identity: build_identity(actor: "agent", user_id: "u-commit")) { }

      expect(current("app.current_user_id")).to eq("")
      expect(current("app.current_agent_id")).to eq("")
    end

    it "is transaction-LOCAL: the values are gone after ROLLBACK" do
      begin
        described_class.open(connection: real, identity: build_identity(actor: "agent", user_id: "u-rollback")) do
          raise ::ActiveRecord::Rollback
        end
      rescue ::ActiveRecord::Rollback
        nil
      end

      expect(current("app.current_user_id")).to eq("")
    end

    # The reserved-keyword collision that forced `quote_ident` on GUC NAMES:
    # `SET LOCAL app.current_role = …` is a syntax error unquoted, while
    # set_config takes the name as data and never parses it as SQL.
    it "sets app.current_role, a name SET could not parse unquoted" do
      value = nil
      described_class.open(connection: real, identity: build_identity(actor: "agent", role: "owner")) do
        value = current("app.current_role")
      end
      expect(value).to eq("owner")
    end

    # The whole point of the row: a value that would have ended a spliced
    # literal early is simply a value.
    it "stores a quote-bearing principal verbatim, executing nothing" do
      hostile = "u-1'; SET app.current_user_id = 'admin"
      value   = nil
      described_class.open(connection: real, identity: build_identity(actor: "human", agent_id: nil, user_id: hostile)) do
        value = current("app.current_user_id")
      end
      expect(value).to eq(hostile)
    end
  end
end
