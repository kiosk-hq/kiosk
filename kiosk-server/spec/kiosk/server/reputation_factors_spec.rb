# frozen_string_literal: true

require 'securerandom'
require 'kiosk/reputation'
require_relative '../../support/postgres'

# Writes one settled checkout for a customer, as the pay path records it.
module ReputationFactorsSpecHelpers
  def create_tables
    Kiosk.configure { |c| c.schema = schema }
    SpecPostgres.recreate_schema(schema)
    [%(DROP TABLE IF EXISTS "#{users}" CASCADE), %(CREATE TABLE "#{users}" (id uuid PRIMARY KEY)), *shipped_ddl].each { conn.execute(it) }
  end

  def shipped_ddl
    defs = Kiosk::Server::SchemaDefinitions
    [defs.identity_tables_sql(schema:, user_id_type: :uuid, user_table: users),
     defs.mandates_sql(schema:, user_id_type: :uuid), defs.visits_sql(schema:, user_id_type: :uuid),
     defs.refunds_sql(schema:)]
  end

  # A new account, and a live assistant on it.
  def account = conn.select_value(%(INSERT INTO "#{users}" (id) VALUES (gen_random_uuid()) RETURNING id))
  def assistant(account) = conn.select_value(%(INSERT INTO "#{schema}".agents (user_id, issuer) VALUES ('#{account}', 'i') RETURNING id))

  # The settlement's PSP reference.
  def settle(cents, at:, account: user, agent: SecureRandom.uuid)
    checkout = insert_checkout(account, agent, cents)
    reference = "pi_#{SecureRandom.hex(4)}"
    conn.execute(<<~SQL.squish)
      INSERT INTO "#{schema}".settlements (checkout_mandate_id, user_id, agent_id, issuer, psp_reference, settled_amount_cents, currency, settled_at)
      VALUES ('#{checkout}', '#{account}', '#{agent}', 'i', '#{reference}', #{cents}, 'eur', '#{at.utc.iso8601}')
    SQL
    reference
  end

  def insert_checkout(account, agent, cents)
    reference = SecureRandom.uuid
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{schema}".checkout_mandates (reference, checkout_hash, user_id, agent_id, issuer, line_items, total_amount_cents, currency, expires_at, sd_jwt)
      VALUES ('#{reference}', '#{reference}', '#{account}', '#{agent}', 'i', '[]', #{cents}, 'eur', now(), 'j') RETURNING id
    SQL
  end
end

# A PSP that refunds every request, as the Stripe adapter answers.
class RefundingPsp < Kiosk::PaymentProviders::Base
  def refund(psp_reference:, amount_cents:, **)
    { psp_reference: "re_#{SecureRandom.hex(4)}", refunded_psp_reference: psp_reference,
      refunded_amount_cents: amount_cents, refunded_at: Time.now.utc }
  end
end

# The engine's own reputation inputs, against a real Postgres: a customer's
# settlements, net of refunds, and recorded visits inside the policy's window.
RSpec.describe Kiosk::Server::ReputationFactors do
  include ReputationFactorsSpecHelpers

  let(:schema) { 'kiosk_reputation_factors_spec' }
  let(:conn)   { ActiveRecord::Base.connection }
  let(:users)  { 'kiosk_reputation_factors_spec_users' }
  let(:user)   { account }
  let(:policy) { Kiosk::Reputation::Policies::RecentSpend.new(within: 7 * 86_400, cap: 100) }

  before do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

    create_tables
  end

  after do
    SpecPostgres.drop_schema(schema)
    conn.execute(%(DROP TABLE IF EXISTS "#{users}" CASCADE)) unless SpecPostgres.error
  end

  # A caller with no assistant row: these examples count spend, not calls.
  def factors = described_class.for(identity: build_identity(actor: 'human', user_id: user), policy: policy)

  it "sums the customer's settlements and recorded visits inside the window" do
    settle(40_00, at: Time.current - 3600)
    Kiosk::Visit.record!(user_id: user, value_cents: 25_00)
    settle(99_00, at: Time.current - (8 * 86_400))

    expect([factors.settled_purchases_count, factors.settled_purchases_cents]).to eq([2, 65_00])
  end

  it 'leaves out the part of a settlement the operator refunded' do
    claim = Kiosk::Server::PaymentClaim.new(RefundingPsp.new, currency: 'eur', model: 'Order', reference: 'order_id', query: 'my_orders')
    claim.refund(psp_reference: settle(40_00, at: Time.current - 3600), amount_cents: 15_00, key: 'order-1')

    expect([factors.settled_purchases_count, factors.settled_purchases_cents]).to eq([1, 25_00])
  end

  it 'records a repeated PSP refund once' do
    psp = RefundingPsp.new
    receipt = psp.refund(psp_reference: settle(40_00, at: Time.current - 3600), amount_cents: 15_00, key: 'order-1')
    allow(psp).to receive(:refund).and_return(receipt)
    claim = Kiosk::Server::PaymentClaim.new(psp, currency: 'eur', model: 'Order', reference: 'order_id', query: 'my_orders')
    2.times { claim.refund(psp_reference: receipt[:refunded_psp_reference], amount_cents: 15_00, key: 'order-1') }

    expect(factors.settled_purchases_cents).to eq(25_00)
  end

  it 'counts no purchase that the operator refunded in full' do
    claim = Kiosk::Server::PaymentClaim.new(RefundingPsp.new, currency: 'eur', model: 'Order', reference: 'order_id', query: 'my_orders')
    claim.refund(psp_reference: settle(40_00, at: Time.current - 3600), amount_cents: 40_00, key: 'order-1')
    Kiosk::Visit.record!(user_id: user, value_cents: 0)

    expect([factors.settled_purchases_count, factors.settled_purchases_cents]).to eq([1, 0])
  end

  it "counts no one else's spend" do
    other = account
    Kiosk::Visit.record!(user_id: other, value_cents: 25_00)
    settle(40_00, at: Time.current - 3600, account: other, agent: assistant(other))

    expect(factors.settled_purchases_cents).to eq(0)
  end

  it 'counts what an assistant of the customer paid on its own account before a binding moved it here' do
    own = account
    agent = assistant(own)
    settle(40_00, at: Time.current - 3600, account: own, agent:)
    conn.execute(%(UPDATE "#{schema}".agents SET user_id = '#{user}' WHERE id = '#{agent}'))

    expect([factors.settled_purchases_count, factors.settled_purchases_cents]).to eq([1, 40_00])
  end

  it 'leaves the factors empty for a policy with no window' do
    expect(described_class.for(identity: build_identity(user_id: user), policy: Kiosk::Reputation::Policy.new))
      .to eq(Kiosk::Reputation::Factors.empty)
  end
end
