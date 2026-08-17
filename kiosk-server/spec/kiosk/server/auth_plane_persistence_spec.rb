# frozen_string_literal: true

require "active_record"
require "json"
require "openssl"
require "rack/mock"
require "securerandom"

# The AUTH/BINDING plane's statements against a REAL Postgres.
#
# WHY THIS FILE EXISTS (K-782, the same argument `executor_persistence_spec.rb`
# makes for the pay path). Everywhere else this plane is driven through
# `FakeConnection`, which records SQL as a string and asserts nothing about
# what a database would do with it. That was tolerable while every value was
# spliced into the statement through `connection.quote` — the text WAS the
# behaviour, and you could read it. It is not tolerable now that the values
# travel as BIND PARAMETERS: a bind carries its value out-of-band, so the one
# thing that can go wrong silently is the TYPE. A `text[]` role list that
# arrives as a scalar string, a uuid that arrives as text, a jsonb attribute
# set stored as a json *string*, a `Time` that loses its zone — none of those
# change the SQL text by one byte and none can be caught by a fake.
#
# Every assertion here was run GREEN against the INTERPOLATED implementation
# first and then re-run against the bind-parameter one, so the conversion is
# provably behaviour-preserving rather than merely green.
#
# Connection from PG* env vars (CI's service) or the local default socket; no
# reachable server → skip, never fail, so DB-less machines stay green (the same
# contract as `device_authorization_stores_spec.rb` and
# `executor_persistence_spec.rb`).
RSpec.describe "auth plane persistence (real Postgres)" do
  AUTH_PLANE_SPEC_SCHEMA = "kiosk_auth_plane_spec"
  # `identity_tables_sql` emits an UNQUALIFIED `REFERENCES "<user_table>"(id)`,
  # so the principals table has to be reachable on the search path. A uniquely
  # named table in `public`, dropped with the schema, keeps that honest without
  # a second search_path to reason about.
  AUTH_PLANE_SPEC_USERS = "kiosk_auth_plane_spec_users"

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
    conn.execute(%(DROP SCHEMA IF EXISTS "#{AUTH_PLANE_SPEC_SCHEMA}" CASCADE))
    conn.execute(%(DROP TABLE IF EXISTS "#{AUTH_PLANE_SPEC_USERS}" CASCADE))
    conn.execute(%(CREATE SCHEMA "#{AUTH_PLANE_SPEC_SCHEMA}"))
    conn.execute(%(CREATE TABLE "#{AUTH_PLANE_SPEC_USERS}" (id uuid PRIMARY KEY DEFAULT gen_random_uuid())))
    # The SHIPPED migration SQL, not hand-written tables: the point of the type
    # assertions below is that the auth plane agrees with the schema operators
    # actually install.
    defs = Kiosk::Server::SchemaDefinitions
    conn.execute(defs.identity_tables_sql(
                   schema: AUTH_PLANE_SPEC_SCHEMA, user_id_type: :uuid,
                   user_table: AUTH_PLANE_SPEC_USERS,
                 ))
    conn.execute(defs.mandates_sql(schema: AUTH_PLANE_SPEC_SCHEMA, user_id_type: :uuid))
    conn.execute(defs.kyc_verified_at_sql(schema: AUTH_PLANE_SPEC_SCHEMA))
    conn.execute(defs.kyc_attributes_sql(schema: AUTH_PLANE_SPEC_SCHEMA))
    conn.execute(defs.agent_governance_columns_sql(schema: AUTH_PLANE_SPEC_SCHEMA))
  end

  after(:context) do
    unless self.class.postgres_error
      conn = ::ActiveRecord::Base.connection
      conn.execute(%(DROP SCHEMA IF EXISTS "#{AUTH_PLANE_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(DROP TABLE IF EXISTS "#{AUTH_PLANE_SPEC_USERS}" CASCADE))
    end
  end

  let(:connection) { ::ActiveRecord::Base.connection }
  let(:holder)     { SecureRandom.uuid }
  let(:other)      { SecureRandom.uuid }
  let(:pem)        { "-----BEGIN PUBLIC KEY-----\n#{SecureRandom.hex(20)}\n-----END PUBLIC KEY-----" }

  before do
    Kiosk.configure do |c|
      c.schema = AUTH_PLANE_SPEC_SCHEMA
      c.issuer = "https://provider.example"
      c.roles  = %i[customer owner]
      # A role is configured throughout, and that is not incidental: with NO
      # `registration_role` the shipped code inserts a literal `NULL` into
      # `allowed_roles`, which the shipped migration declares `NOT NULL`. See
      # the "no registration_role at all" example below — the bug is filed as
      # K-788 and characterised here rather than fixed, because it is not this
      # row's charge.
      c.registration_role = :customer
    end
    connection.execute(%(TRUNCATE #{table('agents')} CASCADE))
    connection.execute(%(TRUNCATE "#{AUTH_PLANE_SPEC_USERS}" CASCADE))
    [holder, other].each do |id|
      connection.exec_query(%(INSERT INTO "#{AUTH_PLANE_SPEC_USERS}" (id) VALUES ($1)), "spec seed", [id])
    end
    # Tokens are not what this file is about; DefaultAgentIdp#issue is covered
    # in default_agent_idp_spec.rb.
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:issue).and_return("kiosk-pop-jwt")
  end

  def table(name) = %("#{AUTH_PLANE_SPEC_SCHEMA}".#{name})

  # Bind-parameterised read helpers, so the spec's own queries can never be the
  # thing that proves a type.
  def one(sql, binds = []) = connection.exec_query(sql, "auth plane spec", binds).to_a.first
  def value(sql, binds = []) = one(sql, binds)&.values&.first

  def agent_row(agent_id)
    one(%(SELECT * FROM #{table('agents')} WHERE id = $1), [agent_id])
  end

  # ── AccountBinding: the uuid principal and the text[] role list ───────────

  describe "AccountBinding.bind! — fresh key" do
    it "stores user_id as a real uuid and allowed_roles as a real text[] (not a string)" do
      result = Kiosk::Server::AccountBinding.bind!(
        public_key_pem: pem, user_id: holder, requested_role: "customer",
      )

      expect(result[:fresh]).to be(true)
      agent_id = result.fetch(:agent_id)
      # `pg_typeof` reads the COLUMN's type, which the INSERT had to satisfy —
      # a text-typed bind would have raised before this line ran.
      expect(value(%(SELECT pg_typeof(user_id)::text FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("uuid")
      expect(value(%(SELECT pg_typeof(allowed_roles)::text FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("text[]")
      # A one-element ARRAY, not the string "{customer}" and not a one-char
      # array — the distinction `ARRAY[$3]::text[]` exists to make.
      expect(value(%(SELECT array_length(allowed_roles, 1) FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq(1)
      expect(value(%(SELECT allowed_roles[1] FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("customer")
      expect(agent_row(agent_id).fetch("public_key")).to eq(pem)
      expect(agent_row(agent_id).fetch("user_id")).to eq(holder)
    end

    # The lookup that decides fresh-vs-rebind takes the CALLER'S key. A PEM
    # carrying a quote character is the shape that would have ended a spliced
    # literal early; through a bind it is simply a key that does not exist.
    it "looks a key up by value, quote characters and all" do
      hostile = "-----BEGIN PUBLIC KEY-----\n' OR '1'='1\n-----END PUBLIC KEY-----"
      first   = Kiosk::Server::AccountBinding.bind!(public_key_pem: hostile, user_id: holder)
      second  = Kiosk::Server::AccountBinding.bind!(public_key_pem: hostile, user_id: holder)

      expect(first[:fresh]).to be(true)
      expect(second[:fresh]).to be(false)              # found the SAME row
      expect(second[:agent_id]).to eq(first[:agent_id])
      expect(value(%(SELECT count(*) FROM #{table('agents')}))).to eq(1)
    end
  end

  describe "AccountBinding.bind! — known key (rebind)" do
    let!(:fresh) do
      Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: other, requested_role: "customer")
    end

    it "remaps the uuid principal and re-writes allowed_roles as a text[]" do
      result = Kiosk::Server::AccountBinding.bind!(
        public_key_pem: pem, user_id: holder, requested_role: "owner",
      )

      expect(result[:fresh]).to be(false)
      expect(result[:agent_id]).to eq(fresh[:agent_id])
      row = agent_row(fresh[:agent_id])
      expect(row.fetch("user_id")).to eq(holder)
      expect(value(%(SELECT allowed_roles[1] FROM #{table('agents')} WHERE id = $1), [fresh[:agent_id]]))
        .to eq("owner")
      expect(value(%(SELECT array_length(allowed_roles, 1) FROM #{table('agents')} WHERE id = $1), [fresh[:agent_id]]))
        .to eq(1)
    end

    it "leaves allowed_roles untouched on a role-less rebind" do
      Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)
      expect(value(%(SELECT allowed_roles[1] FROM #{table('agents')} WHERE id = $1), [fresh[:agent_id]]))
        .to eq("customer")
    end

    # K-783 against a real database rather than a fake: the destructive case is
    # a re-link to the SAME principal, and what makes it destructive is the
    # hook firing at all.
    it "fires no assistant_claimed when the key is already bound to this human" do
      Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)
      fired = []
      Kiosk.configure { |c| c.assistant_claimed = ->(**kw) { fired << kw } }

      Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)
      expect(fired).to be_empty
      expect(agent_row(fresh[:agent_id]).fetch("user_id")).to eq(holder)
    end
  end

  describe "AccountBinding.unlink!" do
    let!(:bound) { Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder) }

    it "revokes the holder's own row" do
      Kiosk::Server::AccountBinding.unlink!(agent_id: bound[:agent_id], user_id: holder)
      expect(agent_row(bound[:agent_id]).fetch("revoked_at")).not_to be_nil
    end

    # The ownership predicate is the security boundary: both halves are binds,
    # and a uuid that belongs to someone else matches nothing.
    it "refuses to revoke a row belonging to a different holder" do
      expect {
        Kiosk::Server::AccountBinding.unlink!(agent_id: bound[:agent_id], user_id: other)
      }.to raise_error(Kiosk::Server::Errors::NotFound)
      expect(agent_row(bound[:agent_id]).fetch("revoked_at")).to be_nil
    end
  end

  # ── AgentRegistration: the same INSERT from the register door ─────────────

  describe "AgentRegistration.call" do
    before do
      # PoW/PoP are covered in their own specs; this file is about the row.
      allow(Kiosk::Server::RegistrationPow).to receive(:gate)
      allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return(nonce: "n")
      allow(Kiosk::Server::AuthChallenge).to receive(:consume!)
      Kiosk.configure do |c|
        c.registration_role  = :customer
        c.assistant_creation = ->(_pubkey) { holder }
      end
    end

    it "writes a uuid principal and a text[] role from the register door too" do
      result = Kiosk::Server::AgentRegistration.call(public_key_pem: pem, signed: "sig")

      expect(value(%(SELECT pg_typeof(allowed_roles)::text FROM #{table('agents')} WHERE id = $1),
                   [result.fetch(:agent_id)])).to eq("text[]")
      expect(value(%(SELECT allowed_roles[1] FROM #{table('agents')} WHERE id = $1),
                   [result.fetch(:agent_id)])).to eq("customer")
      expect(result.fetch(:user_id)).to eq(holder)
    end

    it "answers Conflict for a key it already knows (the lookup is by value)" do
      Kiosk::Server::AgentRegistration.call(public_key_pem: pem, signed: "sig")
      expect { Kiosk::Server::AgentRegistration.call(public_key_pem: pem, signed: "sig") }
        .to raise_error(Kiosk::Server::Errors::Conflict)
    end

    # ── A CHARACTERISATION OF A BUG, NOT AN ENDORSEMENT (K-788) ─────────────
    #
    # Roles are "hook-or-absent" in this series: `registration_role` is
    # OPTIONAL and the code deliberately writes `allowed_roles = NULL` when it
    # is unset. The SHIPPED migration declares that column `text[] NOT NULL
    # DEFAULT '{}'`, so an operator who leaves the role unset cannot register
    # ANY assistant — `/auth/register` 500s on the NOT NULL constraint, and so
    # does a fresh-key bind.
    #
    # It survived because `agent_registration_spec.rb` asserts the opposite
    # ("succeeds with registration_role unset, writing NULL allowed_roles")
    # through a FakeConnection that accepts any statement — the same
    # zero-real-coverage hole this file exists to close. Filed as K-788 and
    # deliberately NOT fixed here (scope rule 3); pinned so that whoever fixes
    # it is told exactly which behaviour they changed.
    it "cannot register at all with no registration_role — NOT NULL on allowed_roles (K-788)" do
      Kiosk.configure { |c| c.registration_role = nil }

      expect { Kiosk::Server::AgentRegistration.call(public_key_pem: pem, signed: "sig") }
        .to raise_error(::ActiveRecord::NotNullViolation, /allowed_roles/)
      expect(value(%(SELECT count(*) FROM #{table('agents')}))).to eq(0)
    end
  end

  # ── KYC: the jsonb cast, the one type a fake can never see ───────────────

  describe "KycAttestationController#mark_kyc_verified! (jsonb)" do
    let(:agent_id) { Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)[:agent_id] }
    let(:controller) { Kiosk::Server::KycAttestationController.new }

    def mark(attrs)
      controller.send(:mark_kyc_verified!, agent_id, attributes: attrs)
    end

    # THE jsonb ASSERTION. One extra `to_json` anywhere on this path stores the
    # attributes as a jsonb STRING; `jsonb_typeof` is the only thing that can
    # tell you, and every `->>` gate downstream would answer NULL for
    # attributes that are demonstrably there.
    it "stores the attributes as a jsonb OBJECT, not a json string" do
      mark("age_over_18" => true, "licence_a" => false)

      expect(value(%(SELECT jsonb_typeof(kyc_attributes) FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("object")
      expect(value(%(SELECT kyc_attributes ->> 'age_over_18' FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("true")
      expect(value(%(SELECT kyc_attributes ->> 'licence_a' FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("false")
      expect(agent_row(agent_id).fetch("kyc_verified_at")).not_to be_nil
    end

    it "round-trips through DefaultAgentIdp, which is what the gates read" do
      mark("age_over_18" => true)
      idp = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new

      expect(idp.kyc_verified?(agent_id)).to be(true)
      expect(idp.kyc_attributes(agent_id)).to eq("age_over_18" => true)
      expect(idp.kyc_has_attributes?(agent_id, [:age_over_18])).to be(true)
    end

    it "stores an empty attestation as an empty OBJECT (a bare binary attestation)" do
      mark({})
      expect(value(%(SELECT jsonb_typeof(kyc_attributes) FROM #{table('agents')} WHERE id = $1), [agent_id]))
        .to eq("object")
      expect(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.kyc_attributes(agent_id)).to eq({})
    end

    # A revoked agent is not attestable — the predicate is a bind, and a
    # quote-bearing agent id is a value that matches nothing rather than SQL.
    it "touches nothing for a revoked agent" do
      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      mark("age_over_18" => true)
      expect(agent_row(agent_id).fetch("kyc_verified_at")).to be_nil
    end
  end

  # ── DefaultAgentIdp: one lookup, four columns, a uuid bind ────────────────

  describe "DefaultAgentIdp lookups" do
    let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }
    let!(:agent_id) { Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)[:agent_id] }

    it "resolves the principal of a live agent and refuses a revoked one" do
      expect(idp.send(:lookup_user_id, agent_id)).to eq(holder)

      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect { idp.send(:lookup_user_id, agent_id) }
        .to raise_error(Kiosk::AgentIdentityProviders::InvalidToken)
    end

    it "reads the stored key back byte-for-byte" do
      real = OpenSSL::PKey::RSA.generate(2048)
      bound = Kiosk::Server::AccountBinding.bind!(public_key_pem: real.public_key.to_pem, user_id: other)
      expect(idp.agent_payment_key(bound[:agent_id]).to_pem).to eq(real.public_key.to_pem)
    end
  end

  # ── ColumnSpendingCap: uuid bind, bigint column ──────────────────────────

  describe "ColumnSpendingCap" do
    let!(:agent_id) { Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)[:agent_id] }

    it "reads the cap of a live agent and nothing for a revoked one" do
      connection.exec_query(
        %(UPDATE #{table('agents')} SET spending_cap_cents = $1 WHERE id = $2), "spec", [5000, agent_id],
      )
      cap = Kiosk::Server::ColumnSpendingCap.new

      expect(cap.call(agent_id: agent_id)).to eq(5000)
      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect(cap.call(agent_id: agent_id)).to be_nil
    end
  end

  # ── AssistantsController: the two-branch statement and its window bind ────

  describe "AssistantsController (manage page)" do
    let(:human)     { build_identity(actor: "human", agent_id: nil, user_id: holder) }
    let!(:agent_id) { Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: holder)[:agent_id] }

    before do
      idp = Class.new do
        def initialize(identity) = @identity = identity
        def verify(_request) = @identity
      end
      Kiosk.configure do |c|
        c.user_idp                   = idp.new(human)
        c.device_authorization_store = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      end
      # The controller pulls its own connection; point it at the real one.
      allow(::ActiveRecord::Base).to receive(:lease_connection).and_return(connection)
    end

    def dispatch(action, method:, params: {})
      path = action == :show ? "" : "/#{action}"
      env  = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/auth/assistants#{path}", method: method, params: params,
      )
      env["rack.session"] = {}
      status, _headers, body = Kiosk::Server::AssistantsController.action(action).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, raw]
    end

    it "writes a free-text label and an integer cap through binds" do
      hostile = "Alice's ' OR 1=1 -- assistant"
      status, = dispatch(:update, method: "POST",
                                  params: { agent_id: agent_id, human_label: hostile,
                                            spending_cap_cents: "2500" })

      expect(status).to eq(200)
      row = agent_row(agent_id)
      expect(row.fetch("human_label")).to eq(hostile)   # stored verbatim, not executed
      expect(row.fetch("spending_cap_cents")).to eq(2500)
    end

    it "will not write across holders (the ownership predicate is a bind pair)" do
      foreign = Kiosk::Server::AccountBinding.bind!(
        public_key_pem: "#{pem}-other", user_id: other,
      )[:agent_id]

      dispatch(:update, method: "POST", params: { agent_id: foreign, human_label: "mine now" })
      expect(agent_row(foreign).fetch("human_label")).to be_nil
    end

    it "lists the holder's assistants with settled spend, windowed through make_interval" do
      Kiosk.configure { |c| c.spending_cap_window_days = 30 }
      status, body = dispatch(:show, method: "GET")

      expect(status).to eq(200)
      expect(body).to include(agent_id[0, 8])
    end

    it "lists them with no window configured (the statement drops the bind)" do
      Kiosk.configure { |c| c.spending_cap_window_days = nil }
      status, body = dispatch(:show, method: "GET")

      expect(status).to eq(200)
      expect(body).to include(agent_id[0, 8])
    end
  end
end
