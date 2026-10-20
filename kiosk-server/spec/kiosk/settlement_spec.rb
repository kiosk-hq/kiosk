# frozen_string_literal: true

require 'active_record'
require 'securerandom'
require_relative '../support/postgres'

# Writes payment receipts straight into a throwaway schema.
module SettlementSpecHelpers
  SCHEMA = 'kiosk_settlement_spec'

  def self.create_schema
    Kiosk.configure { |c| c.schema = SCHEMA }
    SpecPostgres.recreate_schema(SCHEMA)
    ActiveRecord::Base.connection.execute(
      Kiosk::Server::SchemaDefinitions.mandates_sql(schema: SCHEMA, user_id_type: :uuid)
    )
  end

  def conn
    ActiveRecord::Base.connection
  end

  def settle(user_id, line_items)
    agent = SecureRandom.uuid
    intent = insert_intent(user_id, agent)
    cart = insert_cart(user_id, agent, intent, line_items)
    insert_settlement(user_id, agent, cart)
  end

  def insert_intent(user_id, agent)
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{SCHEMA}".intent_mandates (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
        currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{user_id}', '#{agent}', 'i', 's', 1000, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
  end

  def insert_cart(user_id, agent, intent, line_items)
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{SCHEMA}".cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
        total_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{intent}', '#{user_id}', '#{agent}', 'i', '#{line_items.to_json}',
        500, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
  end

  def insert_settlement(user_id, agent, cart)
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{SCHEMA}".settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
        settled_amount_cents, currency, settled_at)
      VALUES ('#{cart}', '#{user_id}', '#{agent}', 'i', 'psp', 500, 'EUR', now())
      RETURNING id
    SQL
  end

  def as(user_id, &)
    Kiosk::Server::SessionContext.open(connection: conn, identity: build_identity(user_id: user_id), &)
  end
end

# The read models over the engine's own payment receipts, against a real
# Postgres; no reachable server skips, as the other persistence specs do.
RSpec.describe Kiosk::Settlement do
  describe 'Kiosk::Settlement and Kiosk::CartMandate' do
    include SettlementSpecHelpers

    before do
      skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

      SettlementSpecHelpers.create_schema
      Kiosk.configure { |c| c.schema = SettlementSpecHelpers::SCHEMA }
    end

    after { SpecPostgres.drop_schema(SettlementSpecHelpers::SCHEMA) }

    let(:mine)  { SecureRandom.uuid }
    let(:other) { SecureRandom.uuid }

    it "reads the settlements of the principal the wire resolved, and no one else's" do
      own = settle(mine, [{ booking_id: 'b-1' }])
      settle(other, [{ booking_id: 'b-2' }])

      expect(as(mine) { described_class.own.pluck(:id) }).to eq([own])
    end

    it 'refuses to answer off the wire rather than answer nothing' do
      expect { described_class.own.to_a }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
    end

    it "finds the settlement whose cart names a line item by the operator's own key" do
      paid = settle(mine, [{ order_id: 'o-1', qty: 2 }])
      settle(mine, [{ order_id: 'o-2' }])

      expect(described_class.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(order_id: 'o-1')).pluck(:id))
        .to eq([paid])
    end
  end
end
