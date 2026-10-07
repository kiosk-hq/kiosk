# frozen_string_literal: true

require "active_record"
require "securerandom"

# The read models over the engine's own payment receipts, against a real
# Postgres; no reachable server skips, as the other persistence specs do.
RSpec.describe "Kiosk::Settlement and Kiosk::CartMandate" do
  SETTLEMENT_SPEC_SCHEMA = "kiosk_settlement_spec"

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

    Kiosk.configure { |c| c.schema = SETTLEMENT_SPEC_SCHEMA }
    defs = Kiosk::Server::SchemaDefinitions
    conn = ::ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{SETTLEMENT_SPEC_SCHEMA}" CASCADE))
    conn.execute(defs.helper_functions_sql(schema: SETTLEMENT_SPEC_SCHEMA, user_id_type: :uuid))
    conn.execute(defs.mandates_sql(schema: SETTLEMENT_SPEC_SCHEMA, user_id_type: :uuid))
    require_relative "../../app/models/kiosk/cart_mandate"
    require_relative "../../app/models/kiosk/settlement"
  end

  after(:context) do
    unless self.class.postgres_error
      ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{SETTLEMENT_SPEC_SCHEMA}" CASCADE))
    end
  end

  let(:conn)  { ::ActiveRecord::Base.connection }
  let(:mine)  { SecureRandom.uuid }
  let(:other) { SecureRandom.uuid }

  def settle(user_id, line_items)
    row = ->(sql) { conn.select_value(sql) }
    s = SETTLEMENT_SPEC_SCHEMA
    agent = SecureRandom.uuid
    intent = row.call(<<~SQL)
      INSERT INTO "#{s}".intent_mandates (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
        currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{user_id}', '#{agent}', 'i', 's', 1000, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
    cart = row.call(<<~SQL)
      INSERT INTO "#{s}".cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
        total_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{intent}', '#{user_id}', '#{agent}', 'i', '#{line_items.to_json}',
        500, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
    row.call(<<~SQL)
      INSERT INTO "#{s}".settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
        settled_amount_cents, currency, settled_at)
      VALUES ('#{cart}', '#{user_id}', '#{agent}', 'i', 'psp', 500, 'EUR', now())
      RETURNING id
    SQL
  end

  def as(user_id, &block)
    Kiosk::Server::SessionContext.open(connection: conn, identity: build_identity(user_id: user_id), &block)
  end

  it "reads the settlements of the principal the wire resolved, and no one else's" do
    own = settle(mine, [{ booking_id: "b-1" }])
    settle(other, [{ booking_id: "b-2" }])

    expect(as(mine) { Kiosk::Settlement.of_current_principal.pluck(:id) }).to eq([own])
  end

  it "refuses to answer off the wire rather than answer nothing" do
    expect { Kiosk::Settlement.of_current_principal.to_a }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
  end

  it "finds the settlement whose cart names a line item by the operator's own key" do
    paid = settle(mine, [{ order_id: "o-1", qty: 2 }])
    settle(mine, [{ order_id: "o-2" }])

    expect(Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(order_id: "o-1")).pluck(:id))
      .to eq([paid])
  end
end
