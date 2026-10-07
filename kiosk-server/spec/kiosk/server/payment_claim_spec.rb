# frozen_string_literal: true

require "active_record"
require "securerandom"

# §11.6's operator half against a real Postgres: one capture per payable row,
# and a paid state that rests on the capture. No reachable server skips, as the
# other persistence specs do.
RSpec.describe Kiosk::Server::PaymentClaim do
  # The receipt models fix their table when first loaded, so this shares the
  # schema settlement_spec.rb loads them with.
  CLAIM_SPEC_SCHEMA = "kiosk_settlement_spec"

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

    Kiosk.configure { |c| c.schema = CLAIM_SPEC_SCHEMA }
    require_relative "../../../app/models/kiosk/cart_mandate"
    require_relative "../../../app/models/kiosk/settlement"
    defs = Kiosk::Server::SchemaDefinitions
    s = CLAIM_SPEC_SCHEMA
    conn = ::ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{s}" CASCADE))
    conn.execute(defs.helper_functions_sql(schema: s, user_id_type: :uuid))
    conn.execute(defs.mandates_sql(schema: s, user_id_type: :uuid))
    conn.execute(<<~SQL)
      CREATE TABLE "#{s}".payables (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL,
        payment_status varchar NOT NULL DEFAULT 'unpaid',
        paid_by_user_id uuid,
        updated_at timestamp NOT NULL DEFAULT now()
      )
    SQL
  end

  after(:context) do
    unless self.class.postgres_error
      ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{CLAIM_SPEC_SCHEMA}" CASCADE))
    end
  end

  # The operator's half: a catalog that prices every row at 500 cents, and a
  # record of every row it was told is paid.
  let(:paid)  { [] }
  let(:price) { 500 }
  let(:seen)  { [] }
  before do
    Kiosk.configure do |c|
      c.cart_price_checker = ->(id, lines) { (seen << [id, lines]) && price }
      c.after_payment      = ->(id) { paid << id }
    end
  end

  let(:conn)   { ::ActiveRecord::Base.connection }
  let(:schema) { CLAIM_SPEC_SCHEMA }
  let(:owner)  { SecureRandom.uuid }
  let(:payer)  { SecureRandom.uuid }
  let(:row)    { conn.select_value(%(INSERT INTO "#{schema}".payables (user_id) VALUES ('#{owner}') RETURNING id)) }
  let(:psp)    { ClaimSpecPsp.new }
  let(:options) { { payer_column: "paid_by_user_id" } }
  subject(:claim) do
    described_class.new(psp, currency: "eur", table: "#{schema}.payables", reference: "booking_id",
                             query: "my_bookings", **options)
  end

  # Every capture it was asked for, and what it was told to do on the next.
  class ClaimSpecPsp < Kiosk::PaymentProviders::Base
    attr_reader :captures
    attr_accessor :during

    def initialize = @captures = []

    def capture(cart, payment_method:)
      @captures << cart.id
      during&.call(cart)
      { psp_reference: "pi_#{cart.id}", settled_amount_cents: cart.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  ClaimSpecCart = Struct.new(:id, :user_id, :currency, :total_amount_cents, :line_items, keyword_init: true)

  def cart_for(id, total: 500, user_id: payer, currency: "EUR", items: [])
    ClaimSpecCart.new(id: SecureRandom.uuid, user_id: user_id, currency: currency, total_amount_cents: total,
             line_items: [{ "booking_id" => id }, *items])
  end

  def status(id = row) = conn.select_value(%(SELECT payment_status FROM "#{schema}".payables WHERE id = '#{id}'))
  def payer_of(id = row) = conn.select_value(%(SELECT paid_by_user_id FROM "#{schema}".payables WHERE id = '#{id}'))

  def settle(id)
    agent = SecureRandom.uuid
    intent = conn.select_value(<<~SQL)
      INSERT INTO "#{schema}".intent_mandates (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
        currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{payer}', '#{agent}', 'i', 's', 1000, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
    cart = conn.select_value(<<~SQL)
      INSERT INTO "#{schema}".cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
        total_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{intent}', '#{payer}', '#{agent}', 'i', '[{"booking_id": "#{id}"}]',
        500, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
    conn.execute(<<~SQL)
      INSERT INTO "#{schema}".settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
        settled_amount_cents, currency, settled_at)
      VALUES ('#{cart}', '#{payer}', '#{agent}', 'i', 'psp', 500, 'EUR', now())
    SQL
  end

  it "captures once, records the payer, and flips the row to paid when the capture returns" do
    claim.capture(cart_for(row))

    expect(psp.captures.size).to eq(1)
    expect(status).to eq("paid")
    expect(payer_of).to eq(payer)
    expect(paid).to eq([row])
  end

  it "publishes the row as paying while its capture is outstanding" do
    psp.during = ->(_) { expect(status).to eq("paying") }

    claim.capture(cart_for(row))
  end

  it "refuses a second chain for the same row while the first is still capturing, before the PSP" do
    refusal = nil
    psp.during = lambda do |_|
      psp.during = nil
      claim.capture(cart_for(row))
    rescue Kiosk::Server::Errors::Forbidden => e
      refusal = e
    end

    claim.capture(cart_for(row))

    expect(refusal&.message).to include("payment in progress", "my_bookings")
    expect(psp.captures.size).to eq(1)
  end

  it "refuses a fresh chain for a row already paid, before the PSP" do
    claim.capture(cart_for(row))

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /already paid/)
    expect(psp.captures.size).to eq(1)
  end

  it "heals a paying row whose capture already settled, and still refuses" do
    conn.execute(%(UPDATE "#{schema}".payables SET payment_status = 'paying' WHERE id = '#{row}'))
    settle(row)

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /already paid/)
    expect(status).to eq("paid")
    expect(psp.captures).to be_empty
  end

  it "hands the operator's catalog the row and the item lines, and charges its price" do
    item = { "sku" => "room", "qty" => 1, "price_cents" => 500 }
    claim.capture(cart_for(row, items: [item]))

    expect(seen).to eq([[row, [item]]])
    expect(psp.captures.size).to eq(1)
  end

  it "releases the claim when the cart total is not the operator's price, and charges nothing" do
    expect { claim.capture(cart_for(row, total: 1)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /cart total 1 does not equal .*500/)
    expect([status, payer_of, psp.captures]).to eq(["unpaid", nil, []])
  end

  it "refuses with the reason the operator's catalog gives" do
    Kiosk.configuration.cart_price_checker = ->(*) { "cart items do not mirror the booking" }

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, "cart items do not mirror the booking")
    expect([status, psp.captures]).to eq(["unpaid", []])
  end

  it "refuses priced lines that do not sum to the cart total, before asking the catalog" do
    lines = [{ "sku" => "a", "qty" => 2, "price_cents" => 200 }]
    expect { claim.capture(cart_for(row, items: lines)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /does not equal the sum of its line items 400/)
    zero = [{ "sku" => "a", "qty" => 0, "price_cents" => 500 }]
    expect { claim.capture(cart_for(row, items: zero)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /positive qty and price_cents/)
    expect([seen, psp.captures]).to eq([[], []])
  end

  it "releases on a definitive decline and keeps the claim on an unknown outcome" do
    psp.during = ->(_) { raise Kiosk::PaymentProviders::PaymentFailed.new("declined", retryable: true) }
    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::PaymentProviders::PaymentFailed)
    expect(status).to eq("unpaid")

    psp.during = ->(_) { raise Kiosk::PaymentProviders::PaymentFailed.new("timeout", retryable: false) }
    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::PaymentProviders::PaymentFailed)
    expect(status).to eq("paying")
  end

  it "refuses a cart in another currency, a cart naming no single row, and an unknown row" do
    expect { claim.capture(cart_for(row, currency: "USD")) }.to raise_error(Kiosk::Server::Errors::Forbidden, /EUR/)
    two = cart_for(row).tap { |c| c.line_items += [{ "booking_id" => SecureRandom.uuid }] }
    expect { claim.capture(two) }.to raise_error(Kiosk::Server::Errors::Forbidden, /exactly one booking_id/)
    expect { claim.capture(cart_for(SecureRandom.uuid)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /not found/)
    expect(psp.captures).to be_empty
  end

  it "answers a reference that is not a uuid with a 400, not a database error" do
    expect { claim.capture(cart_for("1; DROP TABLE x")) }.to raise_error(Kiosk::Server::Errors::BadRequest, /not a uuid/)
  end

  context "with an owner column" do
    let(:options) { { owner_column: "user_id" } }

    it "claims only the payer's own row" do
      expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /not found or not yours/)
      claim.capture(cart_for(row, user_id: owner))
      expect(status).to eq("paid")
    end
  end

  it "forwards the declared port and nothing else" do
    expect(claim.setup_required?(user_id: payer)).to be(false)
    expect(claim).not_to respond_to(:setup_return_user_id)
    expect(claim).not_to respond_to(:saved_method?)

    def psp.setup_return_user_id(params) = params[:uid]
    expect(described_class.new(psp, currency: "eur", table: "t", reference: "r", query: "q")
                          .setup_return_user_id({ uid: "u-1" })).to eq("u-1")
  end

  it "builds the same claim over another PSP" do
    other = ClaimSpecPsp.new
    claim.over(other).capture(cart_for(row))

    expect([other.captures.size, psp.captures.size, payer_of]).to eq([1, 0, payer])
  end
end
