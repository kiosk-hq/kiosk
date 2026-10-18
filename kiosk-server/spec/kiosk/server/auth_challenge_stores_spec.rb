# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/postgres'

# Run against a real Postgres: a throwaway schema built from the shipped
# `auth_challenge_sql`, dropped afterwards. Connection comes from PG* env
# vars (CI's service) or the local default socket; no reachable server →
# skip (never fail) so DB-less machines stay green. Same shape as
# pow_spent_stores_spec.
module AuthChallengeStoresSpec
  AUTH_CHALLENGE_SPEC_SCHEMA = 'kiosk_auth_challenge_store_spec'

  def expiry_row(public_key)
    ActiveRecord::Base.connection.exec_query(<<~SQL.squish, 'spec types', [public_key]).to_a.first
      SELECT pg_typeof(expires_at)::text AS at_type,
             extract(epoch FROM expires_at)::bigint AS at_epoch
      FROM "#{AUTH_CHALLENGE_SPEC_SCHEMA}".auth_challenges
      WHERE public_key = $1
    SQL
  end

  def challenge_count
    ActiveRecord::Base.connection.exec_query(
      %(SELECT count(*)::int AS n FROM "#{AUTH_CHALLENGE_SPEC_SCHEMA}".auth_challenges)
    ).to_a.first.fetch('n')
  end
end

RSpec.shared_context 'auth challenge stores spec: postgres schema' do
  include AuthChallengeStoresSpec

  subject(:store) { described_class.new }

  let(:live) { Time.now.to_i + 300 }
  let(:schema) { AuthChallengeStoresSpec::AUTH_CHALLENGE_SPEC_SCHEMA }

  before(:context) do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

    schema = AuthChallengeStoresSpec::AUTH_CHALLENGE_SPEC_SCHEMA
    SpecPostgres.recreate_schema(schema)
    ActiveRecord::Base.connection.execute(Kiosk::Server::SchemaDefinitions.auth_challenge_sql(schema: schema))
  end

  after(:context) { SpecPostgres.drop_schema(AuthChallengeStoresSpec::AUTH_CHALLENGE_SPEC_SCHEMA) }

  before do
    Kiosk.configure { |c| c.schema = schema }
    ActiveRecord::Base.connection.execute(%(DELETE FROM "#{schema}".auth_challenges))
  end
end

# ── the property the whole row is about ────────────────────────────────

RSpec.describe Kiosk::Server::AuthChallengeStores::ActiveRecord, 'one handshake across two workers (K-751)' do
  include_context 'auth challenge stores spec: postgres schema'

  it 'takes a challenge PUT by a second, independent store instance' do
    worker_a = described_class.new
    worker_b = described_class.new

    worker_a.put('PEM-shared', 'nonce-1', live)
    expect(worker_b.take('PEM-shared', 'nonce-1')).to be(true)
  end

  it 'carries the challenge across a DIFFERENT database connection' do
    # A separate thread checks out its own connection from the AR pool, so
    # the challenge is found through the TABLE and not through any object
    # or connection state the `put` left behind — which is what makes the
    # handshake survive a process boundary.
    store.put('PEM-cross-conn', 'nonce-1', live)

    taken = Thread.new { described_class.new.take('PEM-cross-conn', 'nonce-1') }.value
    expect(taken).to be(true)
  end

  it 'lets exactly one of N racing takes win' do
    store.put('PEM-race', 'nonce-1', live)

    results = Array.new(4) { described_class.new.take('PEM-race', 'nonce-1') }

    expect(results.count(true)).to eq(1)
    expect(results.count(false)).to eq(3)
  end
end

# ── the AuthChallengeStore contract, adapter-side ──────────────────────

RSpec.describe Kiosk::Server::AuthChallengeStores::ActiveRecord, '#take' do
  include_context 'auth challenge stores spec: postgres schema'

  it 'is single-use: the second take of the same nonce is false' do
    store.put('PEM', 'nonce-1', live)
    expect(store.take('PEM', 'nonce-1')).to be(true)
    expect(store.take('PEM', 'nonce-1')).to be(false)
  end

  it 'refuses a WRONG nonce and does NOT consume the outstanding challenge' do
    store.put('PEM', 'nonce-1', live)

    expect(store.take('PEM', 'guessed')).to be(false)
    # Identical to the in-process store: a wrong guess must not burn the
    # challenge, or a third party who knows only the public key could deny
    # its holder every handshake.
    expect(store.take('PEM', 'nonce-1')).to be(true)
  end

  it 'refuses an EXPIRED challenge and refuses an unknown key' do
    store.put('PEM-old', 'nonce-1', Time.now.to_i - 1)
    expect(store.take('PEM-old', 'nonce-1')).to be(false)
    expect(store.take('PEM-never-seen', 'nonce-1')).to be(false)
  end

  it 'returns false for nil arguments without touching the database' do
    expect(store.take(nil, 'nonce-1')).to be(false)
    expect(store.take('PEM', nil)).to be(false)
  end
end

RSpec.describe Kiosk::Server::AuthChallengeStores::ActiveRecord, '#put' do
  include_context 'auth challenge stores spec: postgres schema'

  it 'keeps only the most recently issued challenge for a key' do
    store.put('PEM', 'nonce-old', live)
    store.put('PEM', 'nonce-new', live)

    expect(store.take('PEM', 'nonce-old')).to be(false)
    expect(store.take('PEM', 'nonce-new')).to be(true)
  end

  # ── TYPES, which only a real Postgres can answer (K-782) ─────────────
  #
  # The PEM, the nonce and the expiry travel as BIND PARAMETERS, and a bind
  # carries its value out-of-band — so the one thing that can go wrong
  # SILENTLY is the type. `to_timestamp($3)` is load-bearing: a bare `$3`
  # offers an epoch INTEGER to a timestamptz column. A PEM carrying a quote
  # character is stored verbatim rather than ending a literal.
  it 'writes the expiry to the exact epoch and stores a hostile key verbatim' do
    hostile = "-----BEGIN PUBLIC KEY-----\n' OR 1=1 --\n-----END PUBLIC KEY-----"
    moment  = 1_800_000_071
    store.put(hostile, 'nonce-1', moment)

    row = expiry_row(hostile)
    expect(row.fetch('at_type')).to eq('timestamp with time zone')
    expect(row.fetch('at_epoch')).to eq(moment)
    expect(store.take(hostile, 'nonce-1')).to be(true)
  end

  it 'returns without touching the database for a nil key' do
    expect(store.put(nil, 'nonce-1', live)).to be_nil
  end
end

RSpec.describe Kiosk::Server::AuthChallengeStores::ActiveRecord, '#prune!' do
  include_context 'auth challenge stores spec: postgres schema'

  it 'drops expired rows and leaves live ones' do
    store.put('PEM-live', 'nonce-1', live)
    store.put('PEM-dead', 'nonce-2', Time.now.to_i - 1)

    store.prune!

    expect(challenge_count).to eq(1)
    expect(store.take('PEM-live', 'nonce-1')).to be(true)
  end
end
