# frozen_string_literal: true

require 'securerandom'
require 'kiosk/pow/equihash'
require 'kiosk/reputation'
require_relative '../../support/postgres'

# A backend that accepts the nonce 'solved', so a paid proof costs the spec no work.
module AcceptingEquihash
  def self.verify(nonce:, **) = nonce == 'solved' # rubocop:disable Naming/PredicateMethod -- `verify` is the backend contract Backends.register names
end

# The toll by call count through the real gate, `RecentSpend` and the agents
# table: every Nth tolled call answers 402 until a proof pays for it.
RSpec.describe Kiosk::Server::TolledCalls do
  let(:schema) { 'kiosk_tolled_calls_spec' }
  let(:users)  { 'kiosk_tolled_calls_spec_users' }
  let(:conn)   { ActiveRecord::Base.connection }
  let(:user)   { SecureRandom.uuid }
  let(:agent)  { create_agent }

  before do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

    create_tables
    Kiosk::Reputation::Backends.register('equihash', AcceptingEquihash)
    Kiosk.configure do |c|
      c.schema            = schema
      c.pow_secret        = 'tolled-calls-spec-secret-of-32-bytes'
      c.reputation_policy = Kiosk::Reputation::Policies::RecentSpend.new(within: 7 * 86_400, cap: 100)
    end
  end

  after do
    Kiosk::Reputation::Backends.reset!
    SpecPostgres.drop_schema(schema)
    conn.execute(%(DROP TABLE IF EXISTS "#{users}" CASCADE)) unless SpecPostgres.error
  end

  # The customer, and the shipped DDL of the agents, settlements, visits and refunds.
  def create_tables
    SpecPostgres.recreate_schema(schema)
    [%(DROP TABLE IF EXISTS "#{users}" CASCADE), %(CREATE TABLE "#{users}" (id uuid PRIMARY KEY)),
     %(INSERT INTO "#{users}" (id) VALUES ('#{user}')), *shipped_ddl].each { conn.execute(it) }
  end

  def shipped_ddl
    defs = Kiosk::Server::SchemaDefinitions
    [defs.identity_tables_sql(schema:, user_id_type: :uuid, user_table: users),
     defs.mandates_sql(schema:, user_id_type: :uuid), defs.visits_sql(schema:, user_id_type: :uuid),
     defs.refunds_sql(schema:)]
  end

  # One more assistant of the customer.
  def create_agent = conn.select_value(%(INSERT INTO "#{schema}".agents (user_id, issuer) VALUES ('#{user}', 'i') RETURNING id))

  def visit(cents, at: Time.current)
    conn.exec_query(%(INSERT INTO "#{schema}".visits (user_id, value_cents, visited_at) VALUES ($1, $2, $3)), 'spec', [user, cents, at])
  end

  # An access token of the agent; `jti` names the token.
  def token(jti = 'token-1') = build_identity(user_id: user, agent_id: agent, claims: { jti:, exp: Time.now.to_i + 3600 })

  def call(identity = token, pow: nil)
    Kiosk::Server::PowGate.gate(identity: identity, command: 'query', verb: 'menu', body: {}, pow: pow)
  rescue Kiosk::Server::Errors::PowRequired => e
    e
  end

  # The first call that answers 402, among the next 100.
  def first_tolled_call(identity = token) = (1..100).find { call(identity).is_a?(Kiosk::Server::Errors::PowRequired) }

  def pay(refusal, identity = token) = call(identity, pow: [{ challenge: refusal.challenges.first, nonce: 'solved' }])

  it 'answers 402 on the 10th call of an assistant with no spend, and the paid proof lets that call through' do
    expect(first_tolled_call).to eq(10)
    expect(pay(call)).to eq(:proceed)
  end

  it 'starts a new count of 10 after the paid proof' do
    first_tolled_call
    pay(call)

    expect(first_tolled_call).to eq(10)
  end

  it 'keeps the count when the assistant gets a new access token' do
    5.times { call(token('token-1')) }

    expect(first_tolled_call(token('token-2'))).to eq(5)
  end

  it 'answers 402 on the 20th call at half the cap of recent spend, and on none at the cap' do
    visit(50_00)
    expect(first_tolled_call).to eq(20)

    visit(50_00)
    expect(first_tolled_call).to be_nil
  end

  it 'counts no spend older than the window' do
    visit(100_00, at: Time.current - (8 * 86_400))

    expect(first_tolled_call).to eq(10)
  end

  it 'counts each assistant of one customer on its own' do
    9.times { call }
    other = build_identity(user_id: user, agent_id: create_agent, claims: {})

    expect([call(other), call]).to match([:proceed, an_instance_of(Kiosk::Server::Errors::PowRequired)])
  end
end
