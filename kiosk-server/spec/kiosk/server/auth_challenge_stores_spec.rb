# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Server::AuthChallengeStores do
  let(:live) { Time.now.to_i + 300 }

  # The gap K-751 is about, made executable. This is NOT a defect of
  # AuthChallengeStore — it is its documented scope — but it is the exact reason
  # §15.2 names the auth nonces and the reference needs a shared store: two
  # instances stand in for two Puma workers, and the challenge issued by one is
  # INVISIBLE to the other, so a correctly-signed handshake is rejected.
  describe "the in-process default (Kiosk::Server::AuthChallengeStore)" do
    it "does NOT carry a challenge across independent instances" do
      worker_a = Kiosk::Server::AuthChallengeStore.new
      worker_b = Kiosk::Server::AuthChallengeStore.new

      worker_a.put("PEM-A", "nonce-1", live)
      expect(worker_b.take("PEM-A", "nonce-1")).to be(false) # fail-CLOSED, unlike pow_spent
      expect(worker_a.take("PEM-A", "nonce-1")).to be(true)
    end
  end

  describe Kiosk::Server::AuthChallengeStores::ActiveRecord do
    # Run against a real Postgres: a throwaway schema built from the shipped
    # `auth_challenge_sql`, dropped afterwards. Connection comes from PG* env
    # vars (CI's service) or the local default socket; no reachable server →
    # skip (never fail) so DB-less machines stay green. Same shape as
    # pow_spent_stores_spec.
    AUTH_CHALLENGE_SPEC_SCHEMA = "kiosk_auth_challenge_store_spec"

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
      conn.execute(%(DROP SCHEMA IF EXISTS "#{AUTH_CHALLENGE_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{AUTH_CHALLENGE_SPEC_SCHEMA}"))
      conn.execute(
        Kiosk::Server::SchemaDefinitions.auth_challenge_sql(schema: AUTH_CHALLENGE_SPEC_SCHEMA),
      )
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(
          %(DROP SCHEMA IF EXISTS "#{AUTH_CHALLENGE_SPEC_SCHEMA}" CASCADE),
        )
      end
    end

    subject(:store) { described_class.new }

    before do
      Kiosk.configure { |c| c.schema = AUTH_CHALLENGE_SPEC_SCHEMA }
      ::ActiveRecord::Base.connection.execute(
        %(DELETE FROM "#{AUTH_CHALLENGE_SPEC_SCHEMA}".auth_challenges),
      )
    end

    # ── the property the whole row is about ────────────────────────────────

    describe "one handshake across two workers (K-751)" do
      it "takes a challenge PUT by a second, independent store instance" do
        worker_a = described_class.new
        worker_b = described_class.new

        worker_a.put("PEM-shared", "nonce-1", live)
        expect(worker_b.take("PEM-shared", "nonce-1")).to be(true)
      end

      it "carries the challenge across a DIFFERENT database connection" do
        # A separate thread checks out its own connection from the AR pool, so
        # the challenge is found through the TABLE and not through any object
        # or connection state the `put` left behind — which is what makes the
        # handshake survive a process boundary.
        store.put("PEM-cross-conn", "nonce-1", live)

        taken = Thread.new { described_class.new.take("PEM-cross-conn", "nonce-1") }.value
        expect(taken).to be(true)
      end

      it "lets exactly one of N racing takes win" do
        store.put("PEM-race", "nonce-1", live)

        results = Array.new(4) { described_class.new.take("PEM-race", "nonce-1") }

        expect(results.count(true)).to eq(1)
        expect(results.count(false)).to eq(3)
      end
    end

    # ── the AuthChallengeStore contract, adapter-side ──────────────────────

    describe "#take" do
      it "is single-use: the second take of the same nonce is false" do
        store.put("PEM", "nonce-1", live)
        expect(store.take("PEM", "nonce-1")).to be(true)
        expect(store.take("PEM", "nonce-1")).to be(false)
      end

      it "refuses a WRONG nonce and does NOT consume the outstanding challenge" do
        store.put("PEM", "nonce-1", live)

        expect(store.take("PEM", "guessed")).to be(false)
        # Identical to the in-process store: a wrong guess must not burn the
        # challenge, or a third party who knows only the public key could deny
        # its holder every handshake.
        expect(store.take("PEM", "nonce-1")).to be(true)
      end

      it "refuses an EXPIRED challenge and refuses an unknown key" do
        store.put("PEM-old", "nonce-1", Time.now.to_i - 1)
        expect(store.take("PEM-old", "nonce-1")).to be(false)
        expect(store.take("PEM-never-seen", "nonce-1")).to be(false)
      end

      it "returns false for nil arguments without touching the database" do
        expect(store.take(nil, "nonce-1")).to be(false)
        expect(store.take("PEM", nil)).to be(false)
      end
    end

    describe "#put" do
      it "keeps only the most recently issued challenge for a key" do
        store.put("PEM", "nonce-old", live)
        store.put("PEM", "nonce-new", live)

        expect(store.take("PEM", "nonce-old")).to be(false)
        expect(store.take("PEM", "nonce-new")).to be(true)
      end

      # ── TYPES, which only a real Postgres can answer (K-782) ─────────────
      #
      # The PEM, the nonce and the expiry travel as BIND PARAMETERS, and a bind
      # carries its value out-of-band — so the one thing that can go wrong
      # SILENTLY is the type. `to_timestamp($3)` is load-bearing: a bare `$3`
      # offers an epoch INTEGER to a timestamptz column. A PEM carrying a quote
      # character is stored verbatim rather than ending a literal.
      it "writes the expiry to the exact epoch and stores a hostile key verbatim" do
        hostile = "-----BEGIN PUBLIC KEY-----\n' OR 1=1 --\n-----END PUBLIC KEY-----"
        moment  = 1_800_000_071
        store.put(hostile, "nonce-1", moment)

        row = ::ActiveRecord::Base.connection.exec_query(<<~SQL, "spec types", [hostile]).to_a.first
          SELECT pg_typeof(expires_at)::text AS at_type,
                 extract(epoch FROM expires_at)::bigint AS at_epoch
          FROM "#{AUTH_CHALLENGE_SPEC_SCHEMA}".auth_challenges
          WHERE public_key = $1
        SQL
        expect(row.fetch("at_type")).to eq("timestamp with time zone")
        expect(row.fetch("at_epoch")).to eq(moment)
        expect(store.take(hostile, "nonce-1")).to be(true)
      end

      it "returns without touching the database for a nil key" do
        expect(store.put(nil, "nonce-1", live)).to be_nil
      end
    end

    describe "#prune!" do
      it "drops expired rows and leaves live ones" do
        store.put("PEM-live", "nonce-1", live)
        store.put("PEM-dead", "nonce-2", Time.now.to_i - 1)

        store.prune!

        count = ::ActiveRecord::Base.connection.exec_query(
          %(SELECT count(*)::int AS n FROM "#{AUTH_CHALLENGE_SPEC_SCHEMA}".auth_challenges),
        ).to_a.first.fetch("n")
        expect(count).to eq(1)
        expect(store.take("PEM-live", "nonce-1")).to be(true)
      end
    end
  end
end
