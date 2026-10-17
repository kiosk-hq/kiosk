# frozen_string_literal: true

require 'securerandom'
require 'kiosk/reputation'
require_relative '../../support/postgres'

# Writes one settled chain for a customer, as the pay path records it.
module ReputationFactorsSpecHelpers
  def create_tables
    Kiosk.configure { |c| c.schema = schema }
    SpecPostgres.recreate_schema(schema)
    conn.execute(Kiosk::Server::SchemaDefinitions.mandates_sql(schema: schema, user_id_type: :uuid))
    conn.execute(Kiosk::Server::SchemaDefinitions.visits_sql(schema: schema, user_id_type: :uuid))
  end

  def settle(cents, at:)
    agent = SecureRandom.uuid
    cart  = insert_cart(agent, insert_intent(agent, cents), cents)
    conn.execute(<<~SQL)
      INSERT INTO "#{schema}".settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference, settled_amount_cents, currency, settled_at)
      VALUES ('#{cart}', '#{user}', '#{agent}', 'i', 'pi', #{cents}, 'eur', '#{at.utc.iso8601}')
    SQL
  end

  def insert_intent(agent, cents)
    conn.select_value(<<~SQL)
      INSERT INTO "#{schema}".intent_mandates (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{user}', '#{agent}', 'i', 's', #{cents}, 'eur', now(), 'j') RETURNING id
    SQL
  end

  def insert_cart(agent, intent, cents)
    conn.select_value(<<~SQL)
      INSERT INTO "#{schema}".cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items, total_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{intent}', '#{user}', '#{agent}', 'i', '[]', #{cents}, 'eur', now(), 'j') RETURNING id
    SQL
  end
end

# The engine's own reputation inputs, against a real Postgres: a customer's
# settlements and recorded visits inside the policy's window.
RSpec.describe Kiosk::Server::ReputationFactors do
  include ReputationFactorsSpecHelpers

  let(:schema) { 'kiosk_reputation_factors_spec' }
  let(:conn)   { ActiveRecord::Base.connection }
  let(:user)   { SecureRandom.uuid }
  let(:policy) { Kiosk::Reputation::Policies::RecentSpend.new(trusted_at: 100_00, within: 7 * 86_400) }

  before(:context) { skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error }
  after(:context) { SpecPostgres.drop_schema('kiosk_reputation_factors_spec') }

  before { create_tables }

  def factors = described_class.for(identity: build_identity(user_id: user), policy: policy)

  it "sums the customer's settlements and recorded visits inside the window" do
    settle(40_00, at: Time.now - 3600)
    Kiosk::Visit.record!(user_id: user, value_cents: 25_00)
    settle(99_00, at: Time.now - (8 * 86_400))

    expect([factors.settled_purchases_count, factors.settled_purchases_cents]).to eq([2, 65_00])
  end

  it "counts no one else's spend" do
    Kiosk::Visit.record!(user_id: SecureRandom.uuid, value_cents: 25_00)

    expect(factors.settled_purchases_cents).to eq(0)
  end

  it 'leaves the factors empty for a policy with no window' do
    expect(described_class.for(identity: build_identity(user_id: user), policy: Kiosk::Reputation::Policy.new))
      .to eq(Kiosk::Reputation::Factors.empty)
  end
end
