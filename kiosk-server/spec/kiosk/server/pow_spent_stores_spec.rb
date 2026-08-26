# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Server::PowSpentStores do
  let(:live) { Time.now.to_i + 300 }

  # The gap K-738 is about, made executable. This is NOT a defect of
  # PowSpentStore — it is its documented scope — but it is the exact reason the
  # protocol needs a normative sentence and the reference needs a shared store:
  # two instances stand in for two Puma workers, and the SAME proof is accepted
  # by both.
  describe "the in-process default (Kiosk::Server::PowSpentStore)" do
    it "does NOT hold single-use across independent instances" do
      worker_a = Kiosk::Server::PowSpentStore.new
      worker_b = Kiosk::Server::PowSpentStore.new

      expect(worker_a.claim("k738-replay", live)).to be(true)
      expect(worker_b.claim("k738-replay", live)).to be(true)
    end
  end

  describe Kiosk::Server::PowSpentStores::ActiveRecord do
    # Run against a real Postgres: a throwaway schema built from the shipped
    # `pow_spent_sql`, dropped afterwards. Connection comes from PG* env vars
    # (CI's service) or the local default socket; no reachable server → skip
    # (never fail) so DB-less machines stay green. Same shape as
    # device_authorization_stores_spec.
    POW_SPENT_SPEC_SCHEMA = "kiosk_pow_spent_store_spec"

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
      conn.execute(%(DROP SCHEMA IF EXISTS "#{POW_SPENT_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{POW_SPENT_SPEC_SCHEMA}"))
      conn.execute(Kiosk::Server::SchemaDefinitions.pow_spent_sql(schema: POW_SPENT_SPEC_SCHEMA))
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(
          %(DROP SCHEMA IF EXISTS "#{POW_SPENT_SPEC_SCHEMA}" CASCADE),
        )
      end
    end

    subject(:store) { described_class.new }

    before do
      Kiosk.configure { |c| c.schema = POW_SPENT_SPEC_SCHEMA }
      ::ActiveRecord::Base.connection.execute(%(DELETE FROM "#{POW_SPENT_SPEC_SCHEMA}".pow_spent))
    end

    # ── the property the whole row is about ────────────────────────────────

    describe "single-use ACROSS store instances (K-738)" do
      it "rejects a replay claimed through a second, independent store instance" do
        worker_a = described_class.new
        worker_b = described_class.new

        expect(worker_a.claim("k738-shared", live)).to be(true)
        expect(worker_b.claim("k738-shared", live)).to be(false)
      end

      it "rejects a replay claimed on a DIFFERENT database connection" do
        # A separate thread checks out its own connection from the AR pool, so
        # the exclusion here is decided by the table's PRIMARY KEY and not by
        # any object or connection state the first claim left behind — which is
        # what makes the guarantee survive a process boundary.
        expect(store.claim("k738-cross-conn", live)).to be(true)

        replay = Thread.new { described_class.new.claim("k738-cross-conn", live) }.value
        expect(replay).to be(false)
      end

      it "leaves exactly one row for N racing claims of one id" do
        results = Array.new(4) { described_class.new.claim("k738-race", live) }

        expect(results.count(true)).to eq(1)
        expect(results.count(false)).to eq(3)
      end
    end

    # ── the PowSpentStore contract, adapter-side ───────────────────────────

    describe "#claim" do
      it "returns true the first time and false after" do
        expect(store.claim("a", live)).to be(true)
        expect(store.claim("a", live)).to be(false)
      end

      # ── TYPES, which only a real Postgres can answer (K-782) ─────────────
      #
      # The id and the expiry now travel as BIND PARAMETERS, and a bind carries
      # its value out-of-band — so the one thing that can go wrong SILENTLY is
      # the type. `to_timestamp($2)` is load-bearing and was proven so by
      # deliberately deleting it: with a bare `$2` the epoch INTEGER is offered
      # to a timestamptz column and Postgres answers `PG::DatetimeFieldOverflow:
      # date/time field value out of range: "1800000071"`. (A `.to_s` on the
      # bind, by contrast, is harmless — the single-argument `to_timestamp` has
      # only the numeric overload, so the string parses. Recorded because it is
      # the break that did NOT work.) A challenge id carrying a quote character
      # is stored verbatim rather than ending a literal.
      it "writes the expiry to the exact epoch and stores a hostile id verbatim" do
        hostile = "jti-' OR 1=1 --"
        moment  = 1_800_000_071
        expect(store.claim(hostile, moment)).to be(true)

        row = ::ActiveRecord::Base.connection.exec_query(<<~SQL, "spec types", [hostile]).to_a.first
          SELECT pg_typeof(expires_at)::text AS at_type,
                 extract(epoch FROM expires_at)::bigint AS at_epoch
          FROM "#{POW_SPENT_SPEC_SCHEMA}".pow_spent
          WHERE id = $1
        SQL
        expect(row.fetch("at_type")).to eq("timestamp with time zone")
        expect(row.fetch("at_epoch")).to eq(moment)
        # The whole point of the table: the same hostile id cannot be spent twice.
        expect(store.claim(hostile, live)).to be(false)
      end

      it "returns false for a nil id without touching the database" do
        expect(store.claim(nil, live)).to be(false)
      end

      it "re-claims an id whose expiry has already passed" do
        expired = Time.now.to_i - 1
        expect(store.claim("stale", expired)).to be(true)
        expect(store.claim("stale", live)).to be(true)
      end
    end

    describe "#release" do
      it "un-claims an id so a legitimate retry is not blocked" do
        store.claim("b", live)
        store.release("b")
        expect(store.claim("b", live)).to be(true)
      end

      it "is a no-op for a nil id" do
        expect { store.release(nil) }.not_to raise_error
      end
    end

    describe "#spent?" do
      it "is false before a claim and true after" do
        expect(store.spent?("c")).to be(false)
        store.claim("c", live)
        expect(store.spent?("c")).to be(true)
      end

      it "is false for an entry whose expiry has passed" do
        store.mark_spent("d", Time.now.to_i - 1)
        expect(store.spent?("d")).to be(false)
      end

      it "is false for a nil id" do
        expect(store.spent?(nil)).to be(false)
      end
    end

    describe "#mark_spent" do
      it "is idempotent and visible to a second instance" do
        store.mark_spent("e", live)
        store.mark_spent("e", live)
        expect(described_class.new.spent?("e")).to be(true)
      end

      it "is a no-op for a nil id" do
        expect { store.mark_spent(nil, live) }.not_to raise_error
      end
    end

    describe "#prune!" do
      it "deletes expired entries and keeps live ones" do
        store.mark_spent("gone", Time.now.to_i - 1)
        store.mark_spent("kept", live)

        store.prune!

        expect(store.claim("gone", live)).to be(true) # row was removed
        expect(store.claim("kept", live)).to be(false)
      end

      it "is throttled on the claim path by prune_interval" do
        throttled = described_class.new(prune_interval: 10_000)
        throttled.claim("warm", live) # first claim performs the one sweep
        throttled.mark_spent("expired-after-sweep", Time.now.to_i - 1)

        throttled.claim("another", live)

        expect(
          ::ActiveRecord::Base.connection.execute(
            %(SELECT count(*) AS n FROM "#{POW_SPENT_SPEC_SCHEMA}".pow_spent
              WHERE id = 'expired-after-sweep'),
          ).first.fetch("n"),
        ).to eq(1)
      end
    end

    # ── it is a drop-in for the configured slot ────────────────────────────

    it "is accepted by Kiosk.configuration.pow_spent_store" do
      Kiosk.configure { |c| c.pow_spent_store = store }
      expect(Kiosk.configuration.pow_spent_store).to equal(store)
    end

    it "satisfies the whole PowSpentStore interface" do
      expect(store).to respond_to(:claim, :release, :spent?, :mark_spent)
    end
  end

  describe "Kiosk::Server::SchemaDefinitions.pow_spent_sql" do
    it "keys the table on the challenge id, so the PK is the single-use gate" do
      sql = Kiosk::Server::SchemaDefinitions.pow_spent_sql(schema: "kiosk")

      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".pow_spent))
      expect(sql).to include("id         text        PRIMARY KEY")
      expect(sql).to include("expires_at timestamptz NOT NULL")
    end

    it "defaults the schema to the configured one" do
      Kiosk.configure { |c| c.schema = "acme" }
      expect(Kiosk::Server::SchemaDefinitions.pow_spent_sql).to include(%("acme".pow_spent))
    end

    it "is NOT one of the canonical migrations the install generator lays down" do
      templates = Dir[File.expand_path("../../../lib/generators/kiosk/install/templates/*.tt", __dir__)]
      expect(templates.map { |p| File.basename(p) }).not_to include(a_string_matching(/pow_spent/))
    end
  end
end
