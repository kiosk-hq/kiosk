# frozen_string_literal: true

require 'active_record'
require 'json'
require 'openssl'
require 'rack/mock'
require 'securerandom'

# The AUTH/BINDING plane's statements against a REAL Postgres.
#
# Everywhere else this plane is driven through `FakeConnection`, which records
# SQL as a string and asserts nothing about what a database would do with it.
# The values travel as BIND PARAMETERS, and a bind carries its value
# out-of-band, so the one thing that can go wrong silently is the TYPE. A
# `text[]` role list that arrives as a scalar string, a uuid that arrives as
# text, a jsonb attribute set stored as a json *string*, a `Time` that loses
# its zone — none of those change the SQL text by one byte and none can be
# caught by a fake.
#
# Connection from PG* env vars (CI's service) or the local default socket; no
# reachable server → skip, never fail, so DB-less machines stay green (the same
# contract as `device_authorization_stores_spec.rb` and
# `executor_persistence_spec.rb`).
module AuthPlanePersistenceSpec
  SCHEMA = 'kiosk_auth_plane_spec'
  # `identity_tables_sql` emits an UNQUALIFIED `REFERENCES "<user_table>"(id)`,
  # so the principals table has to be reachable on the search path. A uniquely
  # named table in `public`, dropped with the schema, keeps that honest without
  # a second search_path to reason about.
  USERS = 'kiosk_auth_plane_spec_users'
  # Assistant keys, generated once.
  KEYS = Array.new(4) { OpenSSL::PKey.generate_key('ED25519') }

  # A user IdP that resolves every request to one fixed identity.
  class StaticUserIdp
    def initialize(identity) = @identity = identity
    def verify(_request) = @identity
  end

  # The connection error, or nil when a local Postgres answers. Probed once
  # per process.
  def self.postgres_error
    @postgres_error ||= begin
      connect_postgres
      [nil]
    rescue StandardError => e
      ["#{e.class}: #{e.message}"]
    end
    @postgres_error.first
  end

  def self.connect_postgres
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql',
      host: ENV.fetch('PGHOST', nil),
      username: ENV.fetch('PGUSER', nil),
      password: ENV.fetch('PGPASSWORD', nil),
      database: ENV.fetch('PGDATABASE', 'postgres')
    )
    ActiveRecord::Base.connection.execute('SELECT 1')
  end

  # The SHIPPED migration SQL, not hand-written tables: the type assertions
  # hold the auth plane to the schema operators actually install.
  def self.create_schema(conn)
    drop_schema(conn)
    conn.execute(%(CREATE SCHEMA "#{SCHEMA}"))
    conn.execute(%(CREATE TABLE "#{USERS}" (id uuid PRIMARY KEY DEFAULT gen_random_uuid())))
    KioskTables.create(:identity_tables, :mandates, :refunds, schema: SCHEMA, user_table: USERS)
  end

  def self.drop_schema(conn)
    conn.execute(%(DROP SCHEMA IF EXISTS "#{SCHEMA}" CASCADE))
    conn.execute(%(DROP TABLE IF EXISTS "#{USERS}" CASCADE))
  end

  def table(name) = %("#{SCHEMA}".kiosk_#{name})

  # Empty the agents and principals tables, then insert the given principals.
  def seed_principals(*ids)
    connection.execute(%(TRUNCATE #{table('agents')} CASCADE))
    connection.execute(%(TRUNCATE "#{USERS}" CASCADE))
    ids.each { |id| connection.exec_query(%(INSERT INTO "#{USERS}" (id) VALUES ($1)), 'spec seed', [id]) }
  end

  # Bind-parameterised read helpers, so the spec's own queries can never be the
  # thing that proves a type.
  def one(sql, binds = []) = connection.exec_query(sql, 'auth plane spec', binds).to_a.first
  def value(sql, binds = []) = one(sql, binds)&.values&.first

  def agent_row(agent_id)
    one(%(SELECT * FROM #{table('agents')} WHERE id = $1), [agent_id])
  end

  # The value of `expr` over the agents row `agent_id`.
  def agent_value(expr, agent_id)
    value(%(SELECT #{expr} FROM #{table('agents')} WHERE id = $1), [agent_id])
  end

  # An operator that assigns roles to nobody: no vocabulary and no default.
  def configure_no_roles
    Kiosk.configure do |c|
      c.roles = []
      c.registration_role = nil
    end
  end

  def pem_of(key) = Kiosk::Server::AssistantKey.to_pem(key)

  # The assistant key of an example that names none, and its stored form.
  def key = KEYS[0]
  def pem = pem_of(key)

  # The client of `key`, registered with no toll; the same client again for a live key.
  def register!(key = self.key)
    Kiosk::Server::ClientRegistration.call({ 'jwks' => { 'keys' => [Kiosk::Server::AssistantKey.to_jwk(key)] } })
  end

  # The client of `key`, bound to `user_id`.
  def bind!(user_id, key: self.key, **)
    Kiosk::Server::AccountBinding.bind!(agent_id: register!(key).id, user_id: user_id, **)
  end

  def dispatch(action, method:, params: {})
    path = action == :show ? '' : "/#{action}"
    env  = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/assistants#{path}", method: method, params: params
    )
    env['rack.session'] = {}
    status, _headers, body = Kiosk::Server::AssistantsController.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, raw]
  end

  # A settled receipt for this agent, `days_ago` old; returns its id. The
  # shipped schema hangs a settlement off a checkout mandate. Every value
  # travels as a bind, including the timestamp.
  def settle!(cents:, days_ago:, currency: 'eur')
    value(%(
      INSERT INTO #{table('settlements')}
        (checkout_mandate_id, user_id, agent_id, issuer, psp_reference, settled_amount_cents, currency, settled_at)
      VALUES ($1, $2, $3, 'https://provider.example', $4, $5, $6, $7)
      RETURNING id
    ), [insert_checkout(cents), holder, agent_id, SecureRandom.hex(8), cents, currency, Time.now.utc - (days_ago * 86_400)])
  end

  def insert_checkout(cents)
    reference = SecureRandom.uuid
    value(%(
      INSERT INTO #{table('checkout_mandates')}
        (reference, checkout_hash, user_id, agent_id, issuer, line_items, total_amount_cents,
         currency, expires_at, sd_jwt)
      VALUES ($1, $1, $2, $3, 'https://provider.example', '[]'::jsonb, $4, 'eur',
              now() + interval '1 day', 'sd-jwt')
      RETURNING id
    ), [reference, holder, agent_id, cents])
  end
end

RSpec.shared_context 'with the auth plane database' do
  include AuthPlanePersistenceSpec

  let(:connection) { ActiveRecord::Base.connection }
  let(:holder)     { SecureRandom.uuid }
  let(:other)      { SecureRandom.uuid }
  # The account registration creates for every assistant here.
  let(:assistant)  { SecureRandom.uuid }
  # The one IdP instance every DefaultAgentIdp.new in the code under test returns.
  let(:idp)        { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }

  before do
    skip "no local Postgres reachable (#{AuthPlanePersistenceSpec.postgres_error})" if AuthPlanePersistenceSpec.postgres_error

    AuthPlanePersistenceSpec.create_schema(connection)
    Kiosk.configure do |c|
      c.schema = AuthPlanePersistenceSpec::SCHEMA
      c.issuer = 'https://provider.example'
      c.roles  = %i[customer owner]
      # A role is configured throughout; the examples that turn it off clear
      # the role vocabulary too, and assert the empty-`text[]` shape the
      # role-less path writes.
      c.registration_role = :customer
      c.assistant_creation = ->(_pem) { assistant }
    end
    seed_principals(holder, other, assistant)
    # Tokens are not what this file is about; DefaultAgentIdp#issue is covered
    # in default_agent_idp_spec.rb.
    allow(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp).to receive(:new).and_return(idp)
    allow(idp).to receive(:issue).and_return('access-token')
  end

  after { AuthPlanePersistenceSpec.drop_schema(connection) unless AuthPlanePersistenceSpec.postgres_error }
end

RSpec.shared_context 'with the auth plane register door' do
  include_context 'with the auth plane database'

  before { Kiosk.configure { |c| c.assistant_creation = ->(_pem) { holder } } }
end

RSpec.shared_context 'with two origins on the auth plane database' do
  include_context 'with the auth plane database'

  let(:a) { 'https://provider.example' }
  let(:b) { 'https://second.example' }

  before do
    Kiosk.configure do |c|
      c.additional_origins = [b]
      c.assistant_creation = ->(_pem) { holder }
    end
  end

  def register_on(origin) = Kiosk.with_issuer(origin) { register! }
end

RSpec.shared_context 'with the auth plane manage page' do
  include_context 'with the auth plane database'

  let(:human) { build_identity(actor: 'human', agent_id: nil, user_id: holder) }

  before do
    Kiosk.configure do |c|
      c.user_idp                   = AuthPlanePersistenceSpec::StaticUserIdp.new(human)
      c.device_authorization_store = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
    end
    # The controller pulls its own connection; point it at the real one.
    allow(ActiveRecord::Base).to receive(:lease_connection).and_return(connection)
  end

  def refund!(settlement_id, cents)
    connection.exec_query(%(
      INSERT INTO #{table('refunds')} (settlement_id, psp_reference, refunded_amount_cents, refunded_at)
      VALUES ($1, $2, $3, now())
    ), 'spec seed', [settlement_id, "re_#{SecureRandom.hex(4)}", cents])
  end
end

# ── assistant key rotation (spec Section 5.7), through POST /auth/rotate ────
#
# Real keys, real client assertions, real tokens: the rotation replaces one
# column of a live row, and the row is what keeps the identity, so this runs
# against the shipped schema.
module AgentRotationSpec
  ISSUER = 'https://provider.example'

  delegate :thumbprint, to: Kiosk::Server::AssistantKey

  # A client assertion by `key` for `client_id`.
  def assertion(key, client_id, **claims)
    JWT.encode({ iss: client_id, sub: client_id, aud: ISSUER, exp: Time.now.to_i + 60, jti: SecureRandom.uuid,
                 **claims }, key, 'EdDSA')
  end

  def rotation_body(old_key, new_key, client_id, signed: assertion(old_key, client_id, new_key: thumbprint(new_key)),
                    new_signed: assertion(new_key, client_id))
    { client_assertion_type: Kiosk::Server::ClientAssertion::TYPE, client_assertion: signed,
      new_client_assertion: new_signed, jwks: { keys: [Kiosk::Server::AssistantKey.to_jwk(new_key)] } }
  end

  # [status, parsed body] of POST /kiosk/auth/rotate.
  def rotate(body)
    env = Rack::MockRequest.env_for("#{ISSUER}/kiosk/auth/rotate", method: 'POST', input: JSON.generate(body),
                                                                   'CONTENT_TYPE' => 'application/json')
    status, _headers, raw_body = Kiosk::Server::AuthController.action(:rotate).call(env)
    raw = +''
    raw_body.each { |chunk| raw << chunk }
    [status, JSON.parse(raw)]
  end

  def claims_of(token) = JWT.decode(token, nil, false).first

  def verified?(token)
    !Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.verify('HTTP_AUTHORIZATION' => "DPoP #{token}").nil?
  end
end

RSpec.describe Kiosk::Server::AccountBinding do
  # ── AccountBinding: the uuid principal and the text[] role list ───────────

  describe '.bind!' do
    include_context 'with the auth plane database'

    it 'stores user_id as a real uuid and allowed_roles as a real text[] (not a string)' do
      agent_id = bind!(holder, requested_role: 'customer').id

      # `pg_typeof` reads the COLUMN's type, which the statement had to satisfy —
      # a text-typed bind would have raised before this line ran.
      expect(agent_value('pg_typeof(user_id)::text', agent_id)).to eq('uuid')
      expect(agent_value('pg_typeof(allowed_roles)::text', agent_id)).to eq('text[]')
      # A one-element ARRAY, not the string "{customer}" and not a one-char
      # array — the distinction `ARRAY[$3]::text[]` exists to make.
      expect(agent_value('array_length(allowed_roles, 1)', agent_id)).to eq(1)
      expect(agent_value('allowed_roles[1]', agent_id)).to eq('customer')
      expect(agent_row(agent_id).fetch('public_key')).to eq(pem)
      expect(agent_row(agent_id).fetch('user_id')).to eq(holder)
    end

    # The agent_id travels as a bind, and a value that is not a UUID never
    # reaches the database.
    it 'refuses an agent_id that names no live client, quote characters and all' do
      expect { described_class.bind!(agent_id: "' OR '1'='1", user_id: holder) }.to raise_error(ArgumentError)
      expect { described_class.bind!(agent_id: SecureRandom.uuid, user_id: holder) }.to raise_error(ArgumentError)
    end

    # «No role at all» is the operator that assigns roles to NOBODY, the only
    # one that may leave `registration_role` unset; a declared vocabulary with
    # no default is refused at boot.
    it 'binds with no role at all — an empty text[], not NULL (K-788)' do
      configure_no_roles

      agent_id = bind!(holder).id

      expect(agent_value('pg_typeof(allowed_roles)::text', agent_id)).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', agent_id)).to eq(0)
    end
  end

  describe '.bind! — known key (rebind)' do
    include_context 'with the auth plane database'

    let!(:fresh) { bind!(other, requested_role: 'customer') }

    it 'remaps the uuid principal and re-writes allowed_roles as a text[]' do
      result = bind!(holder, requested_role: 'owner')

      expect(result.id).to eq(fresh.id)
      expect(agent_row(fresh.id).fetch('user_id')).to eq(holder)
      expect(agent_value('allowed_roles[1]', fresh.id)).to eq('owner')
      expect(agent_value('array_length(allowed_roles, 1)', fresh.id)).to eq(1)
    end

    # A role-less rebind resolves the role from the OPERATOR's default, never
    # from the row. The privileged role the key arrived with belonged to the
    # principal it is leaving, so it does not survive the move, and the column
    # is a one-element `text[]` afterwards, not a widened set.
    it 'resets allowed_roles to registration_role on a role-less rebind' do
      bind!(other, requested_role: 'owner')
      expect(agent_value('allowed_roles[1]', fresh.id)).to eq('owner')

      bind!(holder)

      expect(agent_value('allowed_roles[1]', fresh.id)).to eq('customer')
      expect(agent_value('cardinality(allowed_roles)', fresh.id)).to eq(1)
    end

    # An operator that assigns roles to nobody: the rebind writes the EMPTY
    # `text[]`, the same statement shape the fresh-key branch writes, and not a
    # literal NULL into a `NOT NULL` column.
    it 'writes an empty text[] on a role-less rebind when no role is configured' do
      configure_no_roles

      bind!(holder)

      expect(agent_value('pg_typeof(allowed_roles)::text', fresh.id)).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', fresh.id)).to eq(0)
    end

    # The destructive case is a re-link to the SAME principal, and what makes
    # it destructive is the hook firing at all.
    it 'fires no assistant_claimed when the key is already bound to this human' do
      bind!(holder)
      fired = []
      Kiosk.configure { |c| c.assistant_claimed = ->(**kw) { fired << kw } }

      bind!(holder)
      expect(fired).to be_empty
      expect(agent_row(fresh.id).fetch('user_id')).to eq(holder)
    end
  end

  describe '.unlink!' do
    include_context 'with the auth plane database'

    let!(:bound) { bind!(holder) }

    it "revokes the holder's own row" do
      described_class.unlink!(agent_id: bound.id, user_id: holder)
      expect(agent_row(bound.id).fetch('revoked_at')).not_to be_nil
    end

    # The ownership predicate is the security boundary: both halves are binds,
    # and a uuid that belongs to someone else matches nothing.
    it 'refuses to revoke a row belonging to a different holder' do
      expect do
        described_class.unlink!(agent_id: bound.id, user_id: other)
      end.to raise_error(Kiosk::Server::Errors::NotFound)
      expect(agent_row(bound.id).fetch('revoked_at')).to be_nil
    end
  end

  # ── ClientRegistration: the INSERT of the registration door ───────────────

  describe Kiosk::Server::ClientRegistration, '.call' do
    include_context 'with the auth plane register door'

    it 'writes a uuid principal and a text[] role from the registration door' do
      client = register!

      expect(agent_value('pg_typeof(allowed_roles)::text', client.id)).to eq('text[]')
      expect(agent_value('allowed_roles[1]', client.id)).to eq('customer')
      expect(client.user_id).to eq(holder)
    end

    it 'answers the same client for a key it already knows (the lookup is by value)' do
      first = register!
      expect(register!.id).to eq(first.id)
      expect(value(%(SELECT count(*) FROM #{table('agents')}))).to eq(1)
    end

    # ── THE ROLE-LESS PROVIDER, END TO END ──────────────────────────────────────
    #
    # ADR-0011: «registration MUST NOT fail when [registration_role] is unset»,
    # narrowed by ADR-0036 to the operator that declares NO role vocabulary. The
    # shipped migration declares `allowed_roles` as `text[] NOT NULL DEFAULT '{}'`,
    # so "no role" is the EMPTY SET, written explicitly. A fake accepts any
    # statement, which is why this example runs against a database that can say
    # no.
    it 'registers with no registration_role at all, and the client reads back no role (K-788)' do
      configure_no_roles

      client = register!
      # A real `text[]`, not NULL and not the string "{}". `array_length` of an
      # empty array is NULL in Postgres, so `cardinality` says "zero elements".
      expect(agent_value('pg_typeof(allowed_roles)::text', client.id)).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', client.id)).to eq(0)
      expect(agent_value('allowed_roles IS NULL', client.id)).to be(false)
      # The token endpoint mints with this role: nil, not "".
      expect(Kiosk::Server::Client.find(client.id).role).to be_nil
    end
  end

  # ── Two origins: the account namespace is per origin (ADR-0040) ───────────

  describe 'two origins on one deployment' do
    include_context 'with two origins on the auth plane database'

    it 'registers one key on each origin as two clients' do
      on_a = register_on(a)
      on_b = register_on(b)

      expect(on_b.id).not_to eq(on_a.id)
      expect(agent_row(on_a.id).fetch('issuer')).to eq(a)
      expect(agent_row(on_b.id).fetch('issuer')).to eq(b)
    end

    it 'does not find a client on an origin it never registered on' do
      on_a = register_on(a)
      expect(Kiosk.with_issuer(b) { Kiosk::Server::Client.find(on_a.id) }).to be_nil
    end

    it 'does not bind a client of A on B' do
      on_a = register_on(a)
      expect { Kiosk.with_issuer(b) { described_class.bind!(agent_id: on_a.id, user_id: other) } }
        .to raise_error(ArgumentError)
      expect(agent_row(on_a.id).fetch('user_id')).to eq(holder)
    end

    it 'does not unlink across origins' do
      on_a = register_on(a)
      expect { Kiosk.with_issuer(b) { described_class.unlink!(agent_id: on_a.id, user_id: holder) } }
        .to raise_error(Kiosk::Server::Errors::NotFound)
      expect(agent_row(on_a.id).fetch('revoked_at')).to be_nil
    end
  end

  # ── DefaultAgentIdp: one lookup, four columns, a uuid bind ────────────────

  describe Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp, 'lookups' do
    include_context 'with the auth plane database'

    let(:idp) { described_class.new }
    let!(:agent_id) { bind!(holder).id }

    it 'resolves the principal of a live agent and refuses a revoked one' do
      expect(idp.send(:lookup_agent, agent_id).fetch('user_id')).to eq(holder)

      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect { idp.send(:lookup_agent, agent_id) }
        .to raise_error(Kiosk::AgentIdentityProviders::InvalidToken)
    end

    it 'reads the stored key back byte-for-byte' do
      real = AuthPlanePersistenceSpec::KEYS[1]
      expect(idp.agent_payment_key(bind!(other, key: real).id).public_to_pem).to eq(real.public_to_pem)
    end
  end

  # ── ColumnSpendingCap: uuid bind, bigint column ──────────────────────────

  describe Kiosk::Server::ColumnSpendingCap do
    include_context 'with the auth plane database'

    let!(:agent_id) { bind!(holder).id }

    it 'reads the cap of a live agent and nothing for a revoked one' do
      connection.exec_query(
        %(UPDATE #{table('agents')} SET spending_cap_cents = $1, spending_cap_currency = $2 WHERE id = $3), 'spec',
        [5000, 'eur', agent_id]
      )
      cap = described_class.new

      expect(cap.call(agent_id: agent_id)).to eq(amount_cents: 5000, currency: 'eur')
      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect(cap.call(agent_id: agent_id)).to be_nil
    end
  end

  # ── AssistantsController: the manage page against a real Postgres ────────

  describe Kiosk::Server::AssistantsController, 'the manage page' do
    include_context 'with the auth plane manage page'

    let!(:agent_id) { bind!(holder).id }

    # An origin that takes payments, with the cap the page saves read by ColumnSpendingCap.
    before do
      Kiosk.configure do |c|
        c.payment_provider = Object.new
        c.spending_cap     = Kiosk::Server::ColumnSpendingCap.new
      end
    end

    it 'writes a free-text label and an integer cap through binds' do
      hostile = "Alice's ' OR 1=1 -- assistant"
      status, = dispatch(:update, method: 'POST',
                                  params: { agent_id: agent_id, human_label: hostile,
                                            spending_cap: '25', spending_cap_currency: 'eur' })

      expect(status).to eq(200)
      row = agent_row(agent_id)
      expect(row.fetch('human_label')).to eq(hostile) # stored verbatim, not executed
      expect(row.fetch('spending_cap_cents')).to eq(2500)
    end

    it 'does not write across holders (the ownership predicate is a bind pair)' do
      foreign = bind!(other, key: AuthPlanePersistenceSpec::KEYS[1]).id

      dispatch(:update, method: 'POST', params: { agent_id: foreign, human_label: 'mine now' })
      expect(agent_row(foreign).fetch('human_label')).to be_nil
    end

    it 'lists and writes only the assistants of the origin being served' do
      Kiosk.configure { |c| c.additional_origins = ['https://second.example'] }
      elsewhere = Kiosk.with_issuer('https://second.example') do
        bind!(holder, key: AuthPlanePersistenceSpec::KEYS[2]).id
      end

      _, body = Kiosk.with_issuer('https://provider.example') { dispatch(:show, method: 'GET') }
      expect(body).to include(agent_id[0, 8])
      expect(body).not_to include(elsewhere[0, 8])

      Kiosk.with_issuer('https://provider.example') do
        dispatch(:update, method: 'POST', params: { agent_id: elsewhere, human_label: 'crossed' })
      end
      expect(agent_row(elsewhere).fetch('human_label')).to be_nil
    end

    it "lists the holder's assistants with every settlement they paid" do
      settle!(cents: 2500, days_ago: 1)
      settle!(cents: 9900, days_ago: 60)
      status, body = dispatch(:show, method: 'GET')

      expect(status).to eq(200)
      expect(body).to include(agent_id[0, 8])
      expect(body).to match(/Spent: 124.00 EUR\s+— (no )?spending cap/)
    end

    # The page shows what each assistant spent: refunds do not count.
    it 'counts each settlement less its refunds, never below zero' do
      refund!(settle!(cents: 2500, days_ago: 1), 600)
      over_refunded = settle!(cents: 1000, days_ago: 1)
      2.times { refund!(over_refunded, 1000) }

      _, body = dispatch(:show, method: 'GET')
      expect(body).to match(/Spent: 19.00 EUR\s+— (no )?spending cap/)
    end

    it 'shows one figure per currency' do
      settle!(cents: 2500, days_ago: 1)
      settle!(cents: 700, days_ago: 1, currency: 'usd')

      _, body = dispatch(:show, method: 'GET')
      expect(body).to match(/Spent: 25.00 EUR, 7.00 USD\s+— (no )?spending cap/)
    end

    # The fallback, against the failure it is FOR: an origin that never ran the
    # mandates migration. It is the only StatementInvalid the listing swallows,
    # so this also shows the narrow predicate matches the real error.
    it 'still lists, spend-free, when the settlements table is not there' do
      connection.execute(%(DROP TABLE #{table('settlements')} CASCADE))

      status, body = dispatch(:show, method: 'GET')

      expect(status).to eq(200)
      expect(body).to include('Spent: nothing')
    ensure
      %w[refunds payment_mandates checkout_mandates].each { connection.execute(%(DROP TABLE #{table(it)})) }
      KioskTables.create(:mandates, :refunds, schema: AuthPlanePersistenceSpec::SCHEMA)
    end

    # The cap the page saves is the cap the seam reads, in the cap's own currency.
    it 'saves a cap with its currency, and ColumnSpendingCap reads both' do
      dispatch(:update, method: 'POST',
                        params: { agent_id: agent_id, spending_cap: '50', spending_cap_currency: 'EUR' })

      expect(Kiosk::Server::ColumnSpendingCap.new.call(agent_id: agent_id)).to eq(amount_cents: 5000, currency: 'eur')
      _, body = dispatch(:show, method: 'GET')
      expect(body).to include('spending cap 50.00 EUR')
    end

    it 'refuses a stored cap with no currency' do
      expect do
        connection.exec_query(%(UPDATE #{table('agents')} SET spending_cap_cents = 5000 WHERE id = $1),
                              'auth plane spec', [agent_id])
      end.to raise_error(ActiveRecord::StatementInvalid, /spending_cap_currency/)
    end
  end

  describe Kiosk::Server::AgentRotation, 'through POST /auth/rotate' do
    include_context 'with the auth plane database'
    include AgentRotationSpec
    include OauthClients

    let(:old_key) { AuthPlanePersistenceSpec::KEYS[0] }
    let(:new_key) { AuthPlanePersistenceSpec::KEYS[3] }
    let!(:bound)  { bind!(holder, key: old_key, requested_role: 'customer') }

    before do
      Kiosk.configure { |c| c.signing_key = CHECKOUT_SIGNING_KEY }
      allow(idp).to receive(:issue).and_call_original
    end

    it 'puts the new key on the same agent, account and role, and answers the client information' do
      before = agent_row(bound.id)
      status, body = rotate(rotation_body(old_key, new_key, bound.id))

      expect(status).to eq(200)
      expect(body).to include('client_id' => bound.id, 'jwks' => jwks_of(new_key))
      after = agent_row(bound.id)
      expect(after.fetch('public_key')).to eq(pem_of(new_key))
      expect(after.values_at('id', 'user_id', 'allowed_roles')).to eq(before.values_at('id', 'user_id', 'allowed_roles'))
    end

    it 'lets the token endpoint give a token bound to the new key, for the same agent and account' do
      rotate(rotation_body(old_key, new_key, bound.id))
      _, _, body = client_credentials(bound.id, key: new_key)
      claims = claims_of(body.fetch('access_token'))

      expect(claims.fetch('cnf')).to eq('jkt' => thumbprint(new_key))
      expect(claims.values_at('agent_id', 'sub')).to eq([bound.id, holder])
      expect(verified?(body.fetch('access_token'))).to be(true)
    end

    it 'revokes every token issued before it, also in the same second' do
      earlier = idp.issue(agent_id: bound.id, role: :customer)
      rotate(rotation_body(old_key, new_key, bound.id))
      expect(verified?(earlier)).to be(false)
    end

    it 'leaves the old key no client to authenticate as' do
      rotate(rotation_body(old_key, new_key, bound.id))
      expect(client_credentials(bound.id, key: old_key).first).to eq(401)
    end

    it 'refuses an assertion of the old key that names no new key, and changes nothing' do
      status, body = rotate(rotation_body(old_key, new_key, bound.id, signed: assertion(old_key, bound.id)))
      expect([status, body['code']]).to eq([401, 'unauthenticated'])
      expect(agent_row(bound.id).fetch('public_key')).to eq(pem_of(old_key))
    end

    it 'refuses an assertion of the old key that names another key' do
      signed = assertion(old_key, bound.id, new_key: thumbprint(AuthPlanePersistenceSpec::KEYS[1]))
      status, = rotate(rotation_body(old_key, new_key, bound.id, signed: signed))
      expect(status).to eq(401)
    end

    it 'refuses a new key that did not sign its own assertion' do
      new_signed = assertion(AuthPlanePersistenceSpec::KEYS[1], bound.id)
      status, = rotate(rotation_body(old_key, new_key, bound.id, new_signed: new_signed))
      expect(status).to eq(401)
    end

    it 'refuses a client assertion that was already used' do
      signed = assertion(old_key, bound.id, new_key: thumbprint(new_key))
      Kiosk::Server::ClientAssertion.authenticate!(Kiosk::Server::ClientAssertion::TYPE, signed)

      status, = rotate(rotation_body(old_key, new_key, bound.id, signed: signed))
      expect(status).to eq(401)
    end

    it 'answers 401 for a client that is not registered' do
      status, body = rotate(rotation_body(old_key, new_key, SecureRandom.uuid))
      expect([status, body['code']]).to eq([401, 'unauthenticated'])
      expect(body['detail']).to eq('unknown client')
    end

    it 'answers 409 for a new key that is registered already, and changes nothing' do
      register!(new_key)
      status, body = rotate(rotation_body(old_key, new_key, bound.id))

      expect([status, body['code']]).to eq([409, 'conflict'])
      expect(agent_row(bound.id).fetch('public_key')).to eq(pem_of(old_key))
    end

    it 'answers 400 for a jwks that holds no usable key' do
      status, body = rotate(rotation_body(old_key, new_key, bound.id).merge(jwks: { keys: [] }))
      expect([status, body['code']]).to eq([400, 'bad_request'])
    end
  end
end
