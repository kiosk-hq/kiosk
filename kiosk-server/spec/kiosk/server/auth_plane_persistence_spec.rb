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
    defs = Kiosk::Server::SchemaDefinitions
    conn.execute(defs.identity_tables_sql(schema: SCHEMA, user_id_type: :uuid, user_table: USERS))
    conn.execute(defs.mandates_sql(schema: SCHEMA, user_id_type: :uuid))
    conn.execute(defs.refunds_sql(schema: SCHEMA))
  end

  def self.drop_schema(conn)
    conn.execute(%(DROP SCHEMA IF EXISTS "#{SCHEMA}" CASCADE))
    conn.execute(%(DROP TABLE IF EXISTS "#{USERS}" CASCADE))
  end

  def table(name) = %("#{SCHEMA}".#{name})

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

  def bind!(user_id, **) = Kiosk::Server::AccountBinding.bind!(public_key_pem: pem, user_id: user_id, **)
  def register! = Kiosk::Server::AgentRegistration.call(public_key_pem: pem, signed: 'sig')

  # PoW, PoP and the challenge are covered in their own specs; this file is
  # about the row.
  def stub_register_door
    allow(Kiosk::Server::AuthToll).to receive(:gate)
    allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return(nonce: 'n')
    allow(Kiosk::Server::AuthChallenge).to receive(:consume!)
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

  # A settled receipt for this agent, `days_ago` old; returns its id. The chain
  # is what the shipped schema requires: a settlement hangs off a cart mandate,
  # which hangs off an intent. Every value travels as a bind, including the
  # timestamp.
  def settle!(cents:, days_ago:, currency: 'eur')
    cart = insert_cart(insert_intent, cents)
    value(%(
      INSERT INTO #{table('settlements')}
        (cart_mandate_id, user_id, agent_id, issuer, psp_reference, settled_amount_cents, currency, settled_at)
      VALUES ($1, $2, $3, 'https://provider.example', $4, $5, $6, $7)
      RETURNING id
    ), [cart, holder, agent_id, SecureRandom.hex(8), cents, currency, Time.now.utc - (days_ago * 86_400)])
  end

  def insert_intent
    value(%(
      INSERT INTO #{table('intent_mandates')}
        (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents, currency, expires_at, raw_jws)
      VALUES ($1, $2, $3, 'https://provider.example', 'shop', 1000000, 'eur', now() + interval '1 day', 'jws')
      RETURNING id
    ), [SecureRandom.uuid, holder, agent_id])
  end

  def insert_cart(intent, cents)
    value(%(
      INSERT INTO #{table('cart_mandates')}
        (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items, total_amount_cents,
         currency, expires_at, raw_jws)
      VALUES ($1, $2, $3, $4, 'https://provider.example', '[]'::jsonb, $5, 'eur',
              now() + interval '1 day', 'jws')
      RETURNING id
    ), [SecureRandom.uuid, intent, holder, agent_id, cents])
  end
end

RSpec.shared_context 'auth plane persistence spec: database' do
  include AuthPlanePersistenceSpec

  before(:context) do
    skip "no local Postgres reachable (#{AuthPlanePersistenceSpec.postgres_error})" if AuthPlanePersistenceSpec.postgres_error

    AuthPlanePersistenceSpec.create_schema(ActiveRecord::Base.connection)
  end

  after(:context) do
    AuthPlanePersistenceSpec.drop_schema(ActiveRecord::Base.connection) unless AuthPlanePersistenceSpec.postgres_error
  end

  let(:connection) { ActiveRecord::Base.connection }
  let(:holder)     { SecureRandom.uuid }
  let(:other)      { SecureRandom.uuid }
  let(:pem)        { "-----BEGIN PUBLIC KEY-----\n#{SecureRandom.hex(20)}\n-----END PUBLIC KEY-----" }

  before do
    Kiosk.configure do |c|
      c.schema = AuthPlanePersistenceSpec::SCHEMA
      c.issuer = 'https://provider.example'
      c.roles  = %i[customer owner]
      # A role is configured throughout; the examples that turn it off clear
      # the role vocabulary too, and assert the empty-`text[]` shape the
      # role-less path writes.
      c.registration_role = :customer
    end
    seed_principals(holder, other)
    # Tokens are not what this file is about; DefaultAgentIdp#issue is covered
    # in default_agent_idp_spec.rb.
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:issue).and_return('kiosk-pop-jwt')
  end
end

RSpec.shared_context 'auth plane persistence spec: rebind' do
  include_context 'auth plane persistence spec: database'

  let!(:fresh) { bind!(other, requested_role: 'customer') }
end

RSpec.shared_context 'auth plane persistence spec: register door' do
  include_context 'auth plane persistence spec: database'

  before do
    stub_register_door
    Kiosk.configure do |c|
      c.registration_role  = :customer
      c.assistant_creation = ->(_pubkey) { holder }
    end
  end
end

RSpec.shared_context 'auth plane persistence spec: two origins' do
  include_context 'auth plane persistence spec: database'

  let(:a) { 'https://provider.example' }
  let(:b) { 'https://second.example' }

  before do
    stub_register_door
    Kiosk.configure do |c|
      c.additional_origins = [b]
      c.assistant_creation = ->(_pubkey) { holder }
    end
  end

  def register_on(origin) = Kiosk.with_issuer(origin) { register! }
end

RSpec.shared_context 'auth plane persistence spec: manage page' do
  include_context 'auth plane persistence spec: database'

  let(:human)     { build_identity(actor: 'human', agent_id: nil, user_id: holder) }
  let!(:agent_id) { bind!(holder)[:agent_id] }

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

# ── AccountBinding: the uuid principal and the text[] role list ───────────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: database'

  describe 'AccountBinding.bind! — fresh key' do
    it 'stores user_id as a real uuid and allowed_roles as a real text[] (not a string)' do
      result = bind!(holder, requested_role: 'customer')

      expect(result[:fresh]).to be(true)
      agent_id = result.fetch(:agent_id)
      # `pg_typeof` reads the COLUMN's type, which the INSERT had to satisfy —
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
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: database'

  describe 'AccountBinding.bind! — fresh key' do
    # The lookup that decides fresh-vs-rebind takes the CALLER'S key. A PEM
    # carrying a quote character is the shape that would end a spliced literal
    # early; through a bind it is simply a key that does not exist.
    it 'looks a key up by value, quote characters and all' do
      hostile = "-----BEGIN PUBLIC KEY-----\n' OR '1'='1\n-----END PUBLIC KEY-----"
      first   = Kiosk::Server::AccountBinding.bind!(public_key_pem: hostile, user_id: holder)
      second  = Kiosk::Server::AccountBinding.bind!(public_key_pem: hostile, user_id: holder)

      expect(first[:fresh]).to be(true)
      expect(second[:fresh]).to be(false) # found the SAME row
      expect(second[:agent_id]).to eq(first[:agent_id])
      expect(value(%(SELECT count(*) FROM #{table('agents')}))).to eq(1)
    end

    # The claim ceremony's fresh-key branch runs the same INSERT as the
    # register door. «No role at all» is the operator that assigns roles to
    # NOBODY, the only one that may leave `registration_role` unset; a declared
    # vocabulary with no default is refused at boot.
    it 'binds a fresh key with no role at all — an empty text[], not NULL (K-788)' do
      configure_no_roles

      result = bind!(holder)

      expect(result[:fresh]).to be(true)
      expect(agent_value('pg_typeof(allowed_roles)::text', result.fetch(:agent_id))).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', result.fetch(:agent_id))).to eq(0)
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: rebind'

  describe 'AccountBinding.bind! — known key (rebind)' do
    it 'remaps the uuid principal and re-writes allowed_roles as a text[]' do
      result = bind!(holder, requested_role: 'owner')

      expect(result[:fresh]).to be(false)
      expect(result[:agent_id]).to eq(fresh[:agent_id])
      expect(agent_row(fresh[:agent_id]).fetch('user_id')).to eq(holder)
      expect(agent_value('allowed_roles[1]', fresh[:agent_id])).to eq('owner')
      expect(agent_value('array_length(allowed_roles, 1)', fresh[:agent_id])).to eq(1)
    end

    # A role-less rebind resolves the role from the OPERATOR's default, never
    # from the row. The privileged role the key arrived with belonged to the
    # principal it is leaving, so it does not survive the move, and the column
    # is a one-element `text[]` afterwards, not a widened set.
    it 'resets allowed_roles to registration_role on a role-less rebind' do
      bind!(other, requested_role: 'owner')
      expect(agent_value('allowed_roles[1]', fresh[:agent_id])).to eq('owner')

      bind!(holder)

      expect(agent_value('allowed_roles[1]', fresh[:agent_id])).to eq('customer')
      expect(agent_value('cardinality(allowed_roles)', fresh[:agent_id])).to eq(1)
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: rebind'

  describe 'AccountBinding.bind! — known key (rebind)' do
    # An operator that assigns roles to nobody: the rebind writes the EMPTY
    # `text[]`, the same statement shape the fresh-key branch writes, and not a
    # literal NULL into a `NOT NULL` column.
    it 'writes an empty text[] on a role-less rebind when no role is configured' do
      configure_no_roles

      bind!(holder)

      expect(agent_value('pg_typeof(allowed_roles)::text', fresh[:agent_id])).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', fresh[:agent_id])).to eq(0)
    end

    # The destructive case is a re-link to the SAME principal, and what makes
    # it destructive is the hook firing at all.
    it 'fires no assistant_claimed when the key is already bound to this human' do
      bind!(holder)
      fired = []
      Kiosk.configure { |c| c.assistant_claimed = ->(**kw) { fired << kw } }

      bind!(holder)
      expect(fired).to be_empty
      expect(agent_row(fresh[:agent_id]).fetch('user_id')).to eq(holder)
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: database'

  describe 'AccountBinding.unlink!' do
    let!(:bound) { bind!(holder) }

    it "revokes the holder's own row" do
      Kiosk::Server::AccountBinding.unlink!(agent_id: bound[:agent_id], user_id: holder)
      expect(agent_row(bound[:agent_id]).fetch('revoked_at')).not_to be_nil
    end

    # The ownership predicate is the security boundary: both halves are binds,
    # and a uuid that belongs to someone else matches nothing.
    it 'refuses to revoke a row belonging to a different holder' do
      expect do
        Kiosk::Server::AccountBinding.unlink!(agent_id: bound[:agent_id], user_id: other)
      end.to raise_error(Kiosk::Server::Errors::NotFound)
      expect(agent_row(bound[:agent_id]).fetch('revoked_at')).to be_nil
    end
  end
end

# ── AgentRegistration: the same INSERT from the register door ─────────────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: register door'

  describe 'AgentRegistration.call' do
    it 'writes a uuid principal and a text[] role from the register door too' do
      result = register!

      expect(agent_value('pg_typeof(allowed_roles)::text', result.fetch(:agent_id))).to eq('text[]')
      expect(agent_value('allowed_roles[1]', result.fetch(:agent_id))).to eq('customer')
      expect(result.fetch(:user_id)).to eq(holder)
    end

    it 'answers Conflict for a key it already knows (the lookup is by value)' do
      register!
      expect { register! }.to raise_error(Kiosk::Server::Errors::Conflict)
    end
  end
end

# ── THE ROLE-LESS PROVIDER, END TO END ──────────────────────────────────────
#
# ADR-0011: «registration MUST NOT fail when [registration_role] is unset»,
# narrowed by ADR-0036 to the operator that declares NO role vocabulary. The
# shipped migration declares `allowed_roles` as `text[] NOT NULL DEFAULT '{}'`,
# so "no role" is the EMPTY SET, written explicitly. A fake accepts any
# statement, which is why this example runs against a database that can say
# no.
RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: register door'

  describe 'AgentRegistration.call' do
    it 'registers with no registration_role at all, and the row LOGS IN (K-788)' do
      configure_no_roles
      issued = []
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:issue) { |_instance, **kw|
              issued << kw
              'kiosk-pop-jwt'
            }

      agent_id = register!.fetch(:agent_id)
      # A real `text[]`, not NULL and not the string "{}". `array_length` of an
      # empty array is NULL in Postgres, so `cardinality` says "zero elements".
      expect(agent_value('pg_typeof(allowed_roles)::text', agent_id)).to eq('text[]')
      expect(agent_value('cardinality(allowed_roles)', agent_id)).to eq(0)
      expect(agent_value('allowed_roles IS NULL', agent_id)).to be(false)
      # The token carries NO role.
      expect(issued.last).to eq(agent_id: agent_id, role: nil)

      # And the row is usable: `/auth/login` reads `allowed_roles` back and
      # `primary_role` must turn the empty array into nil, not into "".
      expect(Kiosk::Server::AgentLogin.call(public_key_pem: pem, signed: 'sig'))
        .to eq(access_token: 'kiosk-pop-jwt')
      expect(issued.last).to eq(agent_id: agent_id, role: nil)
    end
  end
end

# ── Two origins: the account namespace is per origin (ADR-0040) ───────────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: two origins'

  describe 'two origins on one deployment' do
    it 'registers one key on each origin as two assistant accounts' do
      on_a = register_on(a)
      on_b = register_on(b)

      expect(on_b[:agent_id]).not_to eq(on_a[:agent_id])
      expect(agent_row(on_a[:agent_id]).fetch('issuer')).to eq(a)
      expect(agent_row(on_b[:agent_id]).fetch('issuer')).to eq(b)
    end

    it 'does not log a key in on an origin it never registered on' do
      register_on(a)
      expect { Kiosk.with_issuer(b) { Kiosk::Server::AgentLogin.call(public_key_pem: pem, signed: 'sig') } }
        .to raise_error(Kiosk::Server::Errors::NotFound)
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: two origins'

  describe 'two origins on one deployment' do
    it 'binds a key known on A as a fresh account on B' do
      on_a = register_on(a)
      bound = Kiosk.with_issuer(b) { bind!(other) }

      expect(bound[:fresh]).to be(true)
      expect(agent_row(on_a[:agent_id]).fetch('user_id')).to eq(holder)
    end

    it 'does not unlink across origins' do
      on_a = register_on(a)
      expect { Kiosk.with_issuer(b) { Kiosk::Server::AccountBinding.unlink!(agent_id: on_a[:agent_id], user_id: holder) } }
        .to raise_error(Kiosk::Server::Errors::NotFound)
      expect(agent_row(on_a[:agent_id]).fetch('revoked_at')).to be_nil
    end
  end
end

# ── DefaultAgentIdp: one lookup, four columns, a uuid bind ────────────────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: database'

  describe 'DefaultAgentIdp lookups' do
    let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }
    let!(:agent_id) { bind!(holder)[:agent_id] }

    it 'resolves the principal of a live agent and refuses a revoked one' do
      expect(idp.send(:lookup_user_id, agent_id)).to eq(holder)

      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect { idp.send(:lookup_user_id, agent_id) }
        .to raise_error(Kiosk::AgentIdentityProviders::InvalidToken)
    end

    it 'reads the stored key back byte-for-byte' do
      real = OpenSSL::PKey::RSA.generate(2048)
      bound = Kiosk::Server::AccountBinding.bind!(public_key_pem: real.public_key.to_pem, user_id: other)
      expect(idp.agent_payment_key(bound[:agent_id]).to_pem).to eq(real.public_key.to_pem)
    end
  end
end

# ── ColumnSpendingCap: uuid bind, bigint column ──────────────────────────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: database'

  describe 'ColumnSpendingCap' do
    let!(:agent_id) { bind!(holder)[:agent_id] }

    it 'reads the cap of a live agent and nothing for a revoked one' do
      connection.exec_query(
        %(UPDATE #{table('agents')} SET spending_cap_cents = $1, spending_cap_currency = $2 WHERE id = $3), 'spec',
        [5000, 'eur', agent_id]
      )
      cap = Kiosk::Server::ColumnSpendingCap.new

      expect(cap.call(agent_id: agent_id)).to eq(amount_cents: 5000, currency: 'eur')
      Kiosk::Server::AccountBinding.unlink!(agent_id: agent_id, user_id: holder)
      expect(cap.call(agent_id: agent_id)).to be_nil
    end
  end
end

# ── AssistantsController: the two-branch statement and its window bind ────

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    it 'writes a free-text label and an integer cap through binds' do
      hostile = "Alice's ' OR 1=1 -- assistant"
      status, = dispatch(:update, method: 'POST',
                                  params: { agent_id: agent_id, human_label: hostile,
                                            spending_cap_cents: '2500', spending_cap_currency: 'eur' })

      expect(status).to eq(200)
      row = agent_row(agent_id)
      expect(row.fetch('human_label')).to eq(hostile) # stored verbatim, not executed
      expect(row.fetch('spending_cap_cents')).to eq(2500)
    end

    it 'does not write across holders (the ownership predicate is a bind pair)' do
      foreign = Kiosk::Server::AccountBinding.bind!(public_key_pem: "#{pem}-other", user_id: other)[:agent_id]

      dispatch(:update, method: 'POST', params: { agent_id: foreign, human_label: 'mine now' })
      expect(agent_row(foreign).fetch('human_label')).to be_nil
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    it 'lists and writes only the assistants of the origin being served' do
      Kiosk.configure { |c| c.additional_origins = ['https://second.example'] }
      elsewhere = Kiosk.with_issuer('https://second.example') do
        Kiosk::Server::AccountBinding.bind!(public_key_pem: "#{pem}-second", user_id: holder)[:agent_id]
      end

      _, body = Kiosk.with_issuer('https://provider.example') { dispatch(:show, method: 'GET') }
      expect(body).to include(agent_id[0, 8])
      expect(body).not_to include(elsewhere[0, 8])

      Kiosk.with_issuer('https://provider.example') do
        dispatch(:update, method: 'POST', params: { agent_id: elsewhere, human_label: 'crossed' })
      end
      expect(agent_row(elsewhere).fetch('human_label')).to be_nil
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    before do
      settle!(cents: 2500, days_ago: 1)
      settle!(cents: 9900, days_ago: 60)
    end

    it "lists the holder's assistants with settled spend, windowed through make_interval" do
      Kiosk.configure { |c| c.spending_cap_window_days = 30 }
      status, body = dispatch(:show, method: 'GET')

      expect(status).to eq(200)
      expect(body).to include(agent_id[0, 8])
      # The 60-day-old receipt is outside the window, so the bind reached
      # `make_interval` as a day count.
      expect(body).to include('spent: 2500 cents in EUR —')
    end

    it 'lists them with no window configured (the statement drops the bind)' do
      Kiosk.configure { |c| c.spending_cap_window_days = nil }
      status, body = dispatch(:show, method: 'GET')

      expect(status).to eq(200)
      expect(body).to include(agent_id[0, 8])
      # No window, so both receipts count: the same statement with one bind
      # fewer, which is the branch a mismatched bind list breaks first.
      expect(body).to include('spent: 12400 cents in EUR —')
    end
  end
end

# The page shows the spend the spending cap counts.
RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    it 'counts each settlement less its refunds, never below zero' do
      refund!(settle!(cents: 2500, days_ago: 1), 600)
      over_refunded = settle!(cents: 1000, days_ago: 1)
      2.times { refund!(over_refunded, 1000) }

      _, body = dispatch(:show, method: 'GET')
      expect(body).to include('spent: 1900 cents in EUR —')
    end

    it 'shows one figure per currency' do
      settle!(cents: 2500, days_ago: 1)
      settle!(cents: 700, days_ago: 1, currency: 'usd')

      _, body = dispatch(:show, method: 'GET')
      expect(body).to include('spent: 2500 cents in EUR, 700 cents in USD —')
    end
  end
end

RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    # The fallback, against the failure it is FOR: an origin that never ran the
    # mandates migration. It is the only StatementInvalid the listing swallows,
    # so this also shows the narrow predicate matches the real error.
    it 'still lists, spend-free, when the settlements table is not there' do
      Kiosk.configure { |c| c.spending_cap_window_days = 30 }
      connection.execute(%(DROP TABLE #{table('settlements')} CASCADE))

      status, body = dispatch(:show, method: 'GET')

      expect(status).to eq(200)
      expect(body).to include('spent: 0 cents')
    ensure
      connection.execute(%(DROP TABLE #{table('refunds')}))
      connection.execute(Kiosk::Server::SchemaDefinitions.mandates_sql(
                           schema: AuthPlanePersistenceSpec::SCHEMA, user_id_type: :uuid
                         ))
      connection.execute(Kiosk::Server::SchemaDefinitions.refunds_sql(schema: AuthPlanePersistenceSpec::SCHEMA))
    end
  end
end

# The cap the page saves is the cap the seam reads, in the cap's own currency.
RSpec.describe 'auth plane persistence (real Postgres)' do
  include_context 'auth plane persistence spec: manage page'

  describe 'AssistantsController (manage page)' do
    it 'saves a cap with its currency, and ColumnSpendingCap reads both' do
      dispatch(:update, method: 'POST',
                        params: { agent_id: agent_id, spending_cap_cents: '5000', spending_cap_currency: 'EUR' })

      expect(Kiosk::Server::ColumnSpendingCap.new.call(agent_id: agent_id)).to eq(amount_cents: 5000, currency: 'eur')
      _, body = dispatch(:show, method: 'GET')
      expect(body).to include('cap: 5000 cents in EUR')
    end

    it 'refuses a stored cap with no currency' do
      expect do
        connection.exec_query(%(UPDATE #{table('agents')} SET spending_cap_cents = 5000 WHERE id = $1),
                              'auth plane spec', [agent_id])
      end.to raise_error(ActiveRecord::StatementInvalid, /spending_cap_currency/)
    end
  end
end
