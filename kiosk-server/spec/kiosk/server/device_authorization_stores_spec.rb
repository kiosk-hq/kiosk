# frozen_string_literal: true

# Store-contract spec: the SAME shared examples run against both shipped
# adapters — InMemory always, and the durable ActiveRecord adapter against a
# real Postgres (schema created via SchemaDefinitions migration 004) when one
# is reachable. Without a local Postgres the ActiveRecord context SKIPS
# rather than fails, so the suite stays green on DB-less machines; CI's gems
# matrix provides a Postgres service, so the contract is enforced there.

require "securerandom"

# ─── shared contract ───────────────────────────────────────────────────────

RSpec.shared_examples "a device-authorization store" do
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  def build_authorization(kind: :claim, **overrides)
    _plain, _user, da = Kiosk::Server::DeviceAuthorization.generate(
      client_id: "kiosk-cli", kind: kind, requested_role: "customer",
      public_key_pem: kind == :claim ? "PEM" : nil,
    )
    overrides.empty? ? da : da.with(**overrides)
  end

  describe "#create" do
    it "stores the row and returns it" do
      da = build_authorization
      expect(store.create(da)).to eq(da)
      # Compare by id, not full equality: durable storage truncates
      # timestamps to microseconds.
      expect(store.find_by_device_code_hash(da.device_code_hash).id).to eq(da.id)
    end

    it "raises UniqueConstraintError on duplicate device_code_hash" do
      da = build_authorization
      store.create(da)
      duplicate = build_authorization(device_code_hash: da.device_code_hash)
      expect { store.create(duplicate) }
        .to raise_error(Kiosk::Server::DeviceAuthorizationStores::UniqueConstraintError)
    end

    it "raises UniqueConstraintError on duplicate user_code_hash among pending rows" do
      da = build_authorization
      store.create(da)
      other = build_authorization(user_code_hash: da.user_code_hash)
      expect { store.create(other) }
        .to raise_error(Kiosk::Server::DeviceAuthorizationStores::UniqueConstraintError)
    end

    it "permits reuse of a user_code_hash once the prior row left pending" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id))

      other = build_authorization(user_code_hash: da.user_code_hash)
      expect { store.create(other) }.not_to raise_error
    end

    it "accepts a pre-approved :link row (born approved, user_id stamped)" do
      link = build_authorization(kind: :link).approve(user_id: user_id)
      store.create(link)

      found = store.find_by_device_code_hash(link.device_code_hash)
      expect(found).to be_approved
      expect(found).to be_link
      expect(found.user_id.to_s).to eq(user_id)
    end
  end

  describe "#update" do
    it "replaces the stored row when id matches" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id))

      found = store.find_by_device_code_hash(da.device_code_hash)
      expect(found).to be_approved
      expect(found.user_id.to_s).to eq(user_id)
    end

    it "persists consumption (status + consumed_at)" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id).consume(now: Time.now))

      expect(store.find_by_device_code_hash(da.device_code_hash)).to be_consumed
    end

    it "raises NotFoundError when id has no row" do
      expect { store.update(build_authorization) }
        .to raise_error(Kiosk::Server::DeviceAuthorizationStores::NotFoundError, /not found/)
    end

    # K-1109. `requested_role` is written MID-LIFE now, not only at INSERT: a
    # claim row is born role-less and receives the approving human's role at
    # `approve`. The durable adapter's UPDATE listed four columns and this was
    # not one of them, so on Postgres the approval persisted and the role went
    # nowhere — every claim-bound assistant would have silently fallen back to
    # `registration_role`. The in-memory adapter swaps the whole value object
    # and never had the gap, which is why this belongs in the SHARED contract:
    # a store that is only exercised in memory hides exactly this class of bug.
    it "persists a role stamped at approval (not only at insert)" do
      da = build_authorization(requested_role: nil)
      store.create(da)
      store.update(da.approve(user_id: user_id, role: "owner"))

      expect(store.find_by_device_code_hash(da.device_code_hash).requested_role).to eq("owner")
    end
  end

  # ── K-887: the atomic single-use claim ──────────────────────────────────
  #
  # Run against BOTH adapters, because the whole point is that the guarantee
  # must not depend on which one is configured: the durable adapter carries it
  # in the `AND status = 'approved'` predicate, the in-memory one inside its
  # mutex. A `find` + `update` pair cannot express either.
  describe "#claim_consume" do
    it "consumes an approved row and returns it" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id))

      claimed = store.claim_consume(da.approve(user_id: user_id), now: Time.now)

      expect(claimed).not_to be_nil
      expect(claimed).to be_consumed
      expect(store.find_by_device_code_hash(da.device_code_hash)).to be_consumed
    end

    it "returns nil for the SECOND claim of the same row, given the same pre-race snapshot" do
      da       = build_authorization
      store.create(da)
      approved = da.approve(user_id: user_id)
      store.update(approved)

      first  = store.claim_consume(approved, now: Time.now)
      second = store.claim_consume(approved, now: Time.now)

      expect(first).not_to be_nil
      expect(second).to be_nil
    end

    it "returns nil for a row that is not approved (denied / expired)" do
      da = build_authorization
      store.create(da)
      store.update(da.deny)

      expect(store.claim_consume(da.approve(user_id: user_id), now: Time.now)).to be_nil
      expect(store.find_by_device_code_hash(da.device_code_hash)).to be_denied
    end
  end

  describe "#find_by_device_code_hash" do
    it "returns the row regardless of status (callers check expiry/state themselves)" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id))

      expect(store.find_by_device_code_hash(da.device_code_hash)).to be_approved
    end

    it "round-trips every ceremony field" do
      da = build_authorization
      store.create(da)
      found = store.find_by_device_code_hash(da.device_code_hash)

      expect(found.id).to             eq(da.id)
      expect(found.user_code_hash).to eq(da.user_code_hash)
      expect(found.public_key_pem).to eq(da.public_key_pem)
      expect(found.kind).to           eq(da.kind)
      expect(found.client_id).to      eq(da.client_id)
      expect(found.requested_role).to eq(da.requested_role)
      expect(found.status).to         eq(da.status)
      # Timestamps may round-trip through microsecond-precision storage.
      expect(found.expires_at.to_f).to be_within(0.001).of(da.expires_at.to_f)
      expect(found.created_at.to_f).to be_within(0.001).of(da.created_at.to_f)
    end

    it "returns nil when no row matches" do
      expect(store.find_by_device_code_hash("nope")).to be_nil
    end
  end

  describe "#find_by_user_code_hash" do
    it "returns the pending row" do
      da = build_authorization
      store.create(da)
      expect(store.find_by_user_code_hash(da.user_code_hash).id).to eq(da.id)
    end

    it "returns nil once the row leaves pending (approved/consumed/denied invisible)" do
      da = build_authorization
      store.create(da)
      store.update(da.approve(user_id: user_id))
      expect(store.find_by_user_code_hash(da.user_code_hash)).to be_nil
    end

    it "returns nil when no row matches" do
      expect(store.find_by_user_code_hash("nope")).to be_nil
    end
  end
end

# ─── the contract, run against both adapters ───────────────────────────────

RSpec.describe Kiosk::Server::DeviceAuthorizationStores do
  describe Kiosk::Server::DeviceAuthorizationStores::Base do
    subject(:base) { described_class.new }

    it "declares the five abstract operations" do
      expect { base.create(:x) }
        .to raise_error(NotImplementedError)
      expect { base.update(:x) }
        .to raise_error(NotImplementedError)
      expect { base.find_by_device_code_hash("h") }
        .to raise_error(NotImplementedError)
      expect { base.find_by_user_code_hash("h") }
        .to raise_error(NotImplementedError)
      expect { base.claim_consume(:x) }
        .to raise_error(NotImplementedError)
    end
  end

  describe Kiosk::Server::DeviceAuthorizationStores::InMemory do
    subject(:store) { described_class.new }

    it_behaves_like "a device-authorization store"

    describe "#reset! (test helper)" do
      it "clears all stored rows" do
        _plain, _user, da = Kiosk::Server::DeviceAuthorization.generate(client_id: "kiosk-cli")
        store.create(da)
        store.reset!
        expect(store.size).to eq(0)
      end
    end
  end

  describe Kiosk::Server::DeviceAuthorizationStores::ActiveRecord do
    # Contract run against a real Postgres: a throwaway schema created via
    # the shipped migration-008 SQL, dropped afterwards. Connection comes
    # from PG* env vars (CI's service) or the local default socket; no
    # reachable server → skip (never fail) so DB-less machines stay green.
    SPEC_SCHEMA = "kiosk_da_store_spec"

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
      conn.execute(%(DROP SCHEMA IF EXISTS "#{SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{SPEC_SCHEMA}"))
      conn.execute(
        Kiosk::Server::SchemaDefinitions.device_authorizations_sql(
          schema: SPEC_SCHEMA, user_id_type: :uuid,
        ),
      )
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{SPEC_SCHEMA}" CASCADE))
      end
    end

    subject(:store) { described_class.new }

    before do
      Kiosk.configure { |c| c.schema = SPEC_SCHEMA }
      ::ActiveRecord::Base.connection.execute(%(DELETE FROM "#{SPEC_SCHEMA}".device_authorizations))
    end

    it_behaves_like "a device-authorization store"

    # ── TYPES, which only a real Postgres can answer (K-782) ────────────────
    #
    # Every value this store writes now travels as a BIND PARAMETER, and a bind
    # carries its value out-of-band — so the one thing that can go wrong
    # SILENTLY is the TYPE. `id` and `user_id` are uuid columns and the three
    # instants are timestamptz; none of that is visible in the SQL text, and a
    # fake would accept any of it.
    #
    # `expires_at` is pinned to a NON-UTC, non-whole-hour offset on purpose: a
    # coercion that drops the zone lands 5h30m away, which the epoch assertion
    # catches and a string comparison would not.
    it "stores uuids as uuids and instants to the same epoch, zone and all" do
      moment = Time.at(1_800_000_071).localtime("+05:30")
      user   = SecureRandom.uuid
      _plain, _user_code, da = Kiosk::Server::DeviceAuthorization.generate(client_id: "kiosk-cli")
      da = da.with(expires_at: moment, user_id: user, status: :approved)
      store.create(da)

      row = ::ActiveRecord::Base.connection.exec_query(<<~SQL, "spec types", [da.id]).to_a.first
        SELECT pg_typeof(id)::text          AS id_type,
               pg_typeof(user_id)::text     AS user_type,
               pg_typeof(expires_at)::text  AS at_type,
               extract(epoch FROM expires_at)::bigint AS at_epoch
        FROM "#{SPEC_SCHEMA}".device_authorizations
        WHERE id = $1
      SQL
      expect(row.values_at("id_type", "user_type", "at_type"))
        .to eq(["uuid", "uuid", "timestamp with time zone"])
      expect(row.fetch("at_epoch")).to eq(1_800_000_071)
      expect(store.find_by_device_code_hash(da.device_code_hash).user_id).to eq(user)
    end

    it "translates the PG unique_violation into UniqueConstraintError (real constraint, not a pre-check)" do
      _plain, _user, da = Kiosk::Server::DeviceAuthorization.generate(client_id: "kiosk-cli")
      store.create(da)
      duplicate = da.with(id: SecureRandom.uuid)
      expect { store.create(duplicate) }
        .to raise_error(Kiosk::Server::DeviceAuthorizationStores::UniqueConstraintError)
    end
  end

  describe "Kiosk.configuration.device_authorization_store" do
    # The lazy default is the durable adapter — in-memory dies cross-process,
    # and ActiveRecord is a declared dependency of the gem.
    it "lazy-defaults to the durable ActiveRecord store" do
      expect(Kiosk.configuration.device_authorization_store)
        .to be_a(Kiosk::Server::DeviceAuthorizationStores::ActiveRecord)
    end

    it "memoises the default across accesses" do
      first  = Kiosk.configuration.device_authorization_store
      second = Kiosk.configuration.device_authorization_store
      expect(second).to equal(first)
    end

    it "accepts an explicit store via the setter (InMemory remains available for tests)" do
      custom = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      Kiosk.configure { |c| c.device_authorization_store = custom }
      expect(Kiosk.configuration.device_authorization_store).to equal(custom)
    end

    it "Kiosk.reset! drops any configured store" do
      custom = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      Kiosk.configure { |c| c.device_authorization_store = custom }
      Kiosk.reset!
      expect(Kiosk.configuration.device_authorization_store).not_to equal(custom)
    end
  end
end
