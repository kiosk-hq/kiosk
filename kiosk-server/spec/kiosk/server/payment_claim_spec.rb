# frozen_string_literal: true

require 'active_record'
require 'securerandom'
require 'json_schemer'
require_relative '../../support/postgres'

# The operator's half: a catalog that prices every row at 500 cents, a record of
# every row it was told is paid, and one payable row per example.
module PaymentClaimSpecHelpers
  # The receipt models bind their table on first use, so this shares the
  # schema settlement_spec.rb uses.
  SCHEMA = 'kiosk_settlement_spec'

  # Every capture it was asked for, and what it was told to do on the next.
  class ClaimSpecPsp < Kiosk::PaymentProviders::Base
    attr_reader :captures
    attr_accessor :during

    def initialize
      super
      @captures = []
    end

    def capture(cart, **)
      @captures << cart.id
      during&.call(cart)
      { psp_reference: "pi_#{cart.id}", settled_amount_cents: cart.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  # The operator's payable model.
  class Payable < ApplicationRecord
    self.table_name = "#{SCHEMA}.payables"
    include Kiosk::Owned
    include Kiosk::Payable
  end

  # A payable model with no `updated_at`.
  class Untimed < ApplicationRecord
    self.table_name = "#{SCHEMA}.untimed_payables"
    include Kiosk::Owned
  end

  ClaimSpecCart = Struct.new(:id, :user_id, :currency, :total_amount_cents, :line_items, keyword_init: true)

  def self.included(group)
    group.before(:context) do
      skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

      PaymentClaimSpecHelpers.create_schema
    end
    group.after(:context) { SpecPostgres.drop_schema(SCHEMA) }
    group.before { configure_operator }
  end

  def self.create_schema
    Kiosk.configure { |c| c.schema = SCHEMA }
    defs = Kiosk::Server::SchemaDefinitions
    conn = ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{SCHEMA}" CASCADE))
    conn.execute(defs.helper_functions_sql(schema: SCHEMA, user_id_type: :uuid))
    conn.execute(defs.mandates_sql(schema: SCHEMA, user_id_type: :uuid))
    create_payables(conn)
  end

  def self.create_payables(conn)
    columns = 'id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL, ' \
              "payment_status varchar NOT NULL DEFAULT 'unpaid'"
    conn.execute(%(CREATE TABLE "#{SCHEMA}".payables (#{columns}, updated_at timestamp NOT NULL DEFAULT now())))
    conn.execute(%(CREATE TABLE "#{SCHEMA}".untimed_payables (#{columns})))
  end

  def configure_operator
    Kiosk.configure do |c|
      c.schema             = SCHEMA
      c.cart_price_checker = ->(id, lines) { (seen << [id, lines]) && price }
      c.after_payment      = ->(id) { paid << id }
    end
    serve_topic
  end

  # The claim is the payment provider, and the engine serves its topic.
  def serve_topic
    Kiosk.configure do |c|
      c.payment_provider = claim
      c.event_store      = events
    end
    Kiosk::Server::Events.unregister(Kiosk::Server::PaymentClaim::TOPIC)
    Kiosk::Server::Events.register(**claim.topic)
  end

  def events = @events ||= MemoryEventStore.new

  def paid = @paid ||= []
  def seen = @seen ||= []
  def price = 500
  def conn = ActiveRecord::Base.connection
  def schema = SCHEMA
  def owner = @owner ||= SecureRandom.uuid
  def payer = owner
  def psp = @psp ||= ClaimSpecPsp.new

  def row
    @row ||= conn.select_value(%(INSERT INTO "#{schema}".payables (user_id) VALUES ('#{owner}') RETURNING id))
  end

  def claim
    @claim ||= Kiosk::Server::PaymentClaim.new(psp, currency: 'eur', model: 'PaymentClaimSpecHelpers::Payable',
                                                    reference: 'booking_id', query: 'my_bookings')
  end

  def cart_for(id, total: 500, user_id: payer, currency: 'EUR', items: [])
    ClaimSpecCart.new(id: SecureRandom.uuid, user_id: user_id, currency: currency, total_amount_cents: total,
                      line_items: [{ 'booking_id' => id }, *items])
  end

  def status(id = row) = conn.select_value(%(SELECT payment_status FROM "#{schema}".payables WHERE id = '#{id}'))

  def settle(id)
    agent = SecureRandom.uuid
    intent = insert_intent(agent)
    cart = insert_cart(agent, intent, id)
    conn.execute(<<~SQL.squish)
      INSERT INTO "#{schema}".settlements (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
        settled_amount_cents, currency, settled_at)
      VALUES ('#{cart}', '#{payer}', '#{agent}', 'i', 'psp', 500, 'EUR', now())
    SQL
  end

  def insert_intent(agent)
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{schema}".intent_mandates (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
        currency, expires_at, raw_jws)
      VALUES ('#{SecureRandom.uuid}', '#{payer}', '#{agent}', 'i', 's', 1000, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
  end

  def insert_cart(agent, intent, id, mandate_id: SecureRandom.uuid)
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{schema}".cart_mandates (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
        total_amount_cents, currency, expires_at, raw_jws)
      VALUES ('#{mandate_id}', '#{intent}', '#{payer}', '#{agent}', 'i', '[{"booking_id": "#{id}"}]',
        500, 'EUR', now() + interval '1 day', 'j')
      RETURNING id
    SQL
  end

  # The engine's record of a cart the assistant signed, as phase 1 writes it.
  def record(cart)
    agent = SecureRandom.uuid
    insert_cart(agent, insert_intent(agent), cart.line_items.first['booking_id'], mandate_id: cart.id)
    cart
  end

  def put_status(value) = conn.execute(%(UPDATE "#{schema}".payables SET payment_status = '#{value}' WHERE id = '#{row}'))
end

RSpec.describe Kiosk::Server::PaymentClaim, '#settled' do
  include PaymentClaimSpecHelpers

  it 'runs after_payment for the row the settled cart names, and the capture alone does not' do
    cart = cart_for(row)
    claim.capture(cart)
    expect(paid).to be_empty

    claim.settled(cart)
    expect(paid).to eq([row])
  end

  it 'logs a failing after_payment and answers nil' do
    Kiosk.configuration.after_payment = ->(_) { raise 'refund refused' }

    expect { expect(claim.settled(cart_for(row))).to be_nil }.to output(/after_payment failed for #{row}: refund refused/).to_stderr
  end
end

# §11.6's operator half against a real Postgres: one capture per payable row,
# and a paid state that rests on the capture. No reachable server skips, as the
# other persistence specs do.
RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it 'captures once and flips the row to paid when the capture returns' do
    claim.capture(cart_for(row))

    expect(psp.captures.size).to eq(1)
    expect(status).to eq('paid')
  end

  it 'publishes the row as paying while its capture is outstanding' do
    psp.during = ->(_) { expect(status).to eq('paying') }

    claim.capture(cart_for(row))
  end

  it 'refuses a second chain for the same row while the first is still capturing, before the PSP' do
    refusal = nil
    psp.during = lambda do |_|
      psp.during = nil
      claim.capture(cart_for(row))
    rescue Kiosk::Server::Errors::Forbidden => e
      refusal = e
    end

    claim.capture(cart_for(row))

    expect(refusal&.message).to include('payment in progress', 'my_bookings')
    expect(psp.captures.size).to eq(1)
  end
end

RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it 'refuses a fresh chain for a row already paid, before the PSP' do
    claim.capture(cart_for(row))

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /already paid/)
    expect(psp.captures.size).to eq(1)
  end

  it 'heals a paying row whose capture already settled, and still refuses' do
    conn.execute(%(UPDATE "#{schema}".payables SET payment_status = 'paying' WHERE id = '#{row}'))
    settle(row)

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /already paid/)
    expect(status).to eq('paid')
    expect(psp.captures).to be_empty
  end

  it "hands the operator's catalog the row and the item lines, and charges its price" do
    item = { 'sku' => 'room', 'qty' => 1, 'price_cents' => 500 }
    claim.capture(cart_for(row, items: [item]))

    expect(seen).to eq([[row, [item]]])
    expect(psp.captures.size).to eq(1)
  end
end

RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it "releases the claim when the cart total is not the operator's price, and charges nothing" do
    expect { claim.capture(cart_for(row, total: 1)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /cart total 1 does not equal .*500/)
    expect([status, psp.captures]).to eq(['unpaid', []])
  end

  it "refuses with the reason the operator's catalog gives" do
    Kiosk.configuration.cart_price_checker = ->(*) { 'cart items do not mirror the booking' }

    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::Server::Errors::Forbidden, 'cart items do not mirror the booking')
    expect([status, psp.captures]).to eq(['unpaid', []])
  end

  it 'refuses priced lines that do not sum to the cart total, before asking the catalog' do
    lines = [{ 'sku' => 'a', 'qty' => 2, 'price_cents' => 200 }]
    expect { claim.capture(cart_for(row, items: lines)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /does not equal the sum of its line items 400/)
    zero = [{ 'sku' => 'a', 'qty' => 0, 'price_cents' => 500 }]
    expect { claim.capture(cart_for(row, items: zero)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /positive qty and price_cents/)
    expect([seen, psp.captures]).to eq([[], []])
  end
end

RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it 'releases on a definitive decline and keeps the claim on an unknown outcome' do
    psp.during = ->(_) { raise Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true) }
    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::PaymentProviders::PaymentFailed)
    expect(status).to eq('unpaid')

    psp.during = ->(_) { raise Kiosk::PaymentProviders::PaymentFailed.new('timeout', retryable: false) }
    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::PaymentProviders::PaymentFailed)
    expect(status).to eq('paying')
  end

  it 'releases the claim when the PSP asks for payment setup first' do
    psp.during = ->(_) { raise Kiosk::PaymentProviders::SetupRequired }
    expect { claim.capture(cart_for(row)) }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    expect(status).to eq('unpaid')
  end

  it 'answers the capture and logs when the paid event cannot be sent' do
    allow(Kiosk::Server::Events).to receive(:emit).and_raise('event store down')

    expect { expect(claim.capture(cart_for(row))).to include(settled_amount_cents: 500) }
      .to output(/could not mark #{row} paid: event store down/).to_stderr
    expect(status).to eq('paid')
  end

  it 'refuses a cart in another currency, a cart naming no single row, and an unknown row' do
    expect { claim.capture(cart_for(row, currency: 'USD')) }.to raise_error(Kiosk::Server::Errors::Forbidden, /EUR/)
    two = cart_for(row).tap { |c| c.line_items += [{ 'booking_id' => SecureRandom.uuid }] }
    expect { claim.capture(two) }.to raise_error(Kiosk::Server::Errors::Forbidden, /exactly one booking_id/)
    expect { claim.capture(cart_for(SecureRandom.uuid)) }.to raise_error(Kiosk::Server::Errors::Forbidden, /not found/)
    expect(psp.captures).to be_empty
  end

  it 'answers a reference that is not a uuid with a 400, not a database error' do
    expect { claim.capture(cart_for('1; DROP TABLE x')) }.to raise_error(Kiosk::Server::Errors::BadRequest, /not a uuid/)
  end
end

RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it "refuses a principal paying for another principal's row" do
    expect { claim.capture(cart_for(row, user_id: SecureRandom.uuid)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /not found or not yours/)
    expect([status, psp.captures]).to eq(['unpaid', []])
  end

  it 'forwards the declared port and nothing else' do
    expect(claim.setup_required?(user_id: payer)).to be(false)
    expect(claim).not_to respond_to(:setup_return_user_id)
    expect(claim).not_to respond_to(:saved_method?)

    def psp.setup_return_user_id(params) = params[:uid]
    expect(described_class.new(psp, currency: 'eur', model: 'M', reference: 'r', query: 'q')
                          .setup_return_user_id({ uid: 'u-1' })).to eq('u-1')
  end

  it 'builds the same claim over another PSP' do
    other = PaymentClaimSpecHelpers::ClaimSpecPsp.new
    claim.over(other).capture(cart_for(row))

    expect([other.captures.size, psp.captures.size]).to eq([1, 0])
  end
end

RSpec.describe Kiosk::Server::PaymentClaim do
  include PaymentClaimSpecHelpers

  it 'moves updated_at with the status' do
    conn.execute(%(UPDATE "#{schema}".payables SET updated_at = now() - interval '1 day' WHERE id = '#{row}'))
    claim.capture(cart_for(row))

    expect(PaymentClaimSpecHelpers::Payable.find(row).updated_at).to be > 1.minute.ago
  end

  it 'claims and pays a row whose model has no updated_at' do
    id = conn.select_value(%(INSERT INTO "#{schema}".untimed_payables (user_id) VALUES ('#{owner}') RETURNING id))
    untimed = described_class.new(psp, currency: 'eur', model: 'PaymentClaimSpecHelpers::Untimed',
                                       reference: 'booking_id', query: 'my_bookings')
    untimed.capture(cart_for(id))

    expect(PaymentClaimSpecHelpers::Untimed.find(id).payment_status).to eq('paid')
  end
end

# A repeat of a chain whose capture did not complete (§11.6).
RSpec.describe Kiosk::Server::PaymentClaim, '#resume' do
  include PaymentClaimSpecHelpers

  it 'charges the newest unfinished chain again and flips the row to paid' do
    put_status('paying')
    claim.resume(record(cart_for(row)))

    expect([psp.captures.size, status]).to eq([1, 'paid'])
  end

  it 'claims a row the first call never reached' do
    claim.resume(record(cart_for(row)))

    expect([psp.captures.size, status]).to eq([1, 'paid'])
  end

  it 'charges again a row flipped to paid whose settlement was never written' do
    put_status('paid')
    claim.resume(record(cart_for(row)))

    expect([psp.captures.size, status]).to eq([1, 'paid'])
  end
end

RSpec.describe Kiosk::Server::PaymentClaim, '#resume refusals' do
  include PaymentClaimSpecHelpers

  it 'refuses an older chain while a newer unfinished chain holds the row, before the PSP' do
    older = record(cart_for(row))
    record(cart_for(row))
    put_status('paying')

    expect { claim.resume(older) }.to raise_error(Kiosk::Server::Errors::Forbidden, /payment in progress under another chain/)
    expect(psp.captures).to be_empty
  end

  it 'refuses a chain for a row another chain settled, before the PSP' do
    cart = record(cart_for(row))
    put_status('paid')
    settle(row)

    expect { claim.resume(cart) }.to raise_error(Kiosk::Server::Errors::Forbidden, /already paid/)
    expect(psp.captures).to be_empty
  end
end

# The `payment` topic: the owner hears once that the row was paid.
RSpec.describe Kiosk::Server::PaymentClaim, '#topic' do
  include PaymentClaimSpecHelpers

  it 'pushes one payment event to the owner when the capture returns' do
    claim.capture(cart_for(row))
    claim.mark_paid!(row)

    expect(events.since(owner, 0).map { it.slice('topic', 'subject', 'data') })
      .to eq([{ 'topic' => 'payment', 'subject' => row, 'data' => { 'booking_id' => row, 'payment_state' => 'paid' } }])
  end

  it 'pushes data that satisfies the payload_schema the origin serves for the topic' do
    claim.capture(cart_for(row))
    claim.announce(row, 'refunded')

    served = JSON.parse(Kiosk::Server::SchemaDocument.json).fetch('events').find { it['name'] == 'payment' }
    schema = JSONSchemer.schema(served['payload_schema'])
    expect(events.since(owner, 0).flat_map { schema.validate(it['data']).to_a }).to be_empty
  end

  it 'publishes the payment topic with reach principal' do
    served = JSON.parse(Kiosk::Server::SchemaDocument.json).fetch('events').find { it['name'] == 'payment' }
    expect(served['reach']).to eq('principal')
  end

  it "reaches the row's owner and nobody else" do
    reachable = claim.topic[:subject_reachable]
    identity = ->(user_id) { Struct.new(:user_id).new(user_id) }

    expect([reachable.call(row, identity.call(owner)), reachable.call(row, identity.call(SecureRandom.uuid))])
      .to eq([true, false])
  end
end

# Kiosk::Payable: what the payable row publishes about its money, and the cart
# that pays for it.
RSpec.describe Kiosk::Payable do
  include PaymentClaimSpecHelpers

  def read(id = row) = PaymentClaimSpecHelpers::Payable.with_settlement(Kiosk::Settlement.all).find(id)

  it 'reads unpaid, pending while the capture runs, paid after it, and refunded' do
    states = [read.payment_state]
    psp.during = ->(_) { states << read.payment_state }
    claim.capture(cart_for(row))
    states << read.payment_state
    put_status('refunded')

    expect(states << read.payment_state).to eq(%w[unpaid pending paid refunded])
  end

  it 'reads paid on a settlement whose row still says paying, with or without with_settlement' do
    put_status('paying')
    settle(row)

    expect([read.payment_state, PaymentClaimSpecHelpers::Payable.find(row).payment_state]).to eq(%w[paid paid])
    expect(read.settled_currency).to eq('EUR')
  end

  it "finds the settlement that paid the row, and no other row's" do
    settle(row)
    other = conn.select_value(%(INSERT INTO "#{schema}".payables (user_id) VALUES ('#{owner}') RETURNING id))

    expect([read.settlement&.currency, read(other).settlement, read(other).settled_currency]).to eq(['EUR', nil, nil])
  end

  it 'builds the cart a PaymentClaim accepts: a line naming the row, then the priced lines' do
    cart = read.cart([{ sku: 'room', qty: 2, price_cents: 250 }])

    expect(cart).to eq(currency: 'eur', total_amount_cents: 500,
                       line_items: [{ 'booking_id' => row }, { sku: 'room', qty: 2, price_cents: 250 }])
    signed = cart_for(row, total: cart[:total_amount_cents], items: [cart[:line_items].last.stringify_keys])
    claim.capture(signed)
    expect(status).to eq('paid')
  end
end
