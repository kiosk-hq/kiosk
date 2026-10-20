# frozen_string_literal: true

require 'active_record'
require 'securerandom'

# The four `persist_*` helpers — plus `spent_in_window` — against a REAL
# Postgres.
#
# WHY THIS FILE EXISTS. Everywhere else the Executor is driven through
# `FakeConnection`, which records SQL as a string and asserts nothing about
# what a database would do with it; `executor_spec.rb` STUBS all four persist
# helpers outright, so until this file the only place kiosk-server writes to
# the database on the pay path had no coverage of what actually lands in the
# row. That was tolerable while every value was spliced into the SQL text
# through `connection.quote` — the text WAS the behaviour, and you could read
# it. It is not tolerable now that the values travel as BIND PARAMETERS
# (K-654): a bind carries its value out-of-band, so the one thing that can go
# wrong silently is the TYPE. A jsonb argument that arrives as a json *string*,
# a uuid that arrives as text, a `Time` that loses its zone — none of those
# change the SQL text by one byte, and none of them can be caught by a fake.
# Only a real Postgres can tell you.
#
# These specs were written and run GREEN against the interpolated
# implementation FIRST, then re-run against the bind-parameter one, so the
# conversion is provably behaviour-preserving rather than merely green.
#
# Connection from PG* env vars (CI's service) or the local default socket; no
# reachable server → skip, never fail, so DB-less machines stay green (the same
# contract as `device_authorization_stores_spec.rb` and `pow_spent_stores_spec.rb`).
module ExecutorPersistenceSpec
  # Deliberately NOT named SPEC_SCHEMA: `device_authorization_stores_spec.rb`
  # already defines a top-level constant by that name, and a second one would
  # silently overwrite it for whichever file loads later.
  PERSIST_SPEC_SCHEMA = 'kiosk_executor_persist_spec'

  def self.postgres_error
    @postgres_error ||= begin
      connect
      [false]
    rescue StandardError => e
      ["#{e.class}: #{e.message}"]
    end
    @postgres_error.first
  end

  def self.connect
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql',
      host: ENV.fetch('PGHOST', nil),
      username: ENV.fetch('PGUSER', nil),
      password: ENV.fetch('PGPASSWORD', nil),
      database: ENV.fetch('PGDATABASE', 'postgres')
    )
    ActiveRecord::Base.connection.execute('SELECT 1')
  end

  def self.create_schema
    conn = ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{PERSIST_SPEC_SCHEMA}" CASCADE))
    conn.execute(%(CREATE SCHEMA "#{PERSIST_SPEC_SCHEMA}"))
    # The SHIPPED migration SQL, not a hand-written table: the point of the
    # type assertions below is that the executor agrees with the schema
    # operators actually install.
    conn.execute(
      Kiosk::Server::SchemaDefinitions.mandates_sql(
        schema: PERSIST_SPEC_SCHEMA, user_id_type: :uuid
      )
    )
    conn.execute(Kiosk::Server::SchemaDefinitions.refunds_sql(schema: PERSIST_SPEC_SCHEMA))
  end

  module Helpers
    def table(name) = %("#{PERSIST_SPEC_SCHEMA}".#{name})

    # Bind-parameterised read helper, so the spec's own queries can never be
    # the thing that proves a type.
    def one(sql, binds = [])
      connection.exec_query(sql, 'persist spec', binds).to_a.first
    end

    def value(sql, binds = [])
      one(sql, binds)&.values&.first
    end

    # Persist the whole trail; returns the three server ids.
    def persist_trail
      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: payment)
      [intent_row, cart_row]
    end

    # What the cap counts for this assistant: settled plus in flight.
    def settled_total(currency:, agent_id: agent_uuid, window_days: nil)
      spender = described_class.new(connection: connection, identity: build_identity(user_id: user_uuid, agent_id: agent_id))
      spender.send(:spent_in_window, Struct.new(:currency).new(currency), window_days)
    end
  end

  module Replay
    def pay
      described_class.call(kind: :pay, args: args, identity: identity, connection: connection)
    end

    def settlement_count
      value("SELECT count(*) FROM #{table('settlements')}").to_i
    end
  end
end

RSpec.shared_context 'with real Postgres for executor persistence' do
  include ExecutorPersistenceSpec::Helpers

  before do
    skip "no local Postgres reachable (#{ExecutorPersistenceSpec.postgres_error})" if ExecutorPersistenceSpec.postgres_error

    ExecutorPersistenceSpec.create_schema
  end

  after do
    ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{ExecutorPersistenceSpec::PERSIST_SPEC_SCHEMA}" CASCADE)) unless ExecutorPersistenceSpec.postgres_error
  end

  let(:connection) { ActiveRecord::Base.connection }
  let(:user_uuid)  { SecureRandom.uuid }
  let(:agent_uuid) { SecureRandom.uuid }
  let(:identity)   { build_identity(user_id: user_uuid, agent_id: agent_uuid) }
  let(:executor)   { described_class.new(connection: connection, identity: identity) }

  before do
    Kiosk.configure do |c|
      c.schema = ExecutorPersistenceSpec::PERSIST_SPEC_SCHEMA
      c.issuer = 'https://demo.example'
    end
  end
end

RSpec.shared_context 'with a mandate trail to persist' do
  include_context 'with real Postgres for executor persistence'

  # A fixed, non-round instant pinned to an offset that is NOT UTC and not
  # whole-hour, on purpose: the value reaches Postgres as a zone-LESS
  # `YYYY-MM-DD HH:MM:SS` string that the session interprets in UTC, so any
  # coercion that forgets to convert first lands 5h30m away and the epoch
  # assertion fails. (`MandateVerifier` builds these with `Time.at`, whose
  # zone is the server's, so "already UTC" must never be assumed.)
  let(:expires_at) { Time.at(1_800_000_071).localtime('+05:30') }

  let(:intent) do
    Kiosk::Mandate::IntentMandate.new(
      id: "intent-#{SecureRandom.hex(6)}", user_id: user_uuid, agent_id: agent_uuid,
      issuer: 'https://demo.example', scope: 'groceries', cap_amount_cents: 5000,
      currency: 'eur', expires_at: expires_at, created_at: expires_at, raw_jws: 'intent-jws'
    )
  end

  let(:line_items) { [{ 'sku' => 'pizza', 'qty' => 2 }, { 'sku' => 'cola', 'qty' => 1 }] }

  let(:cart) do
    Kiosk::Mandate::CartMandate.new(
      id: "cart-#{SecureRandom.hex(6)}", intent_mandate_id: intent.id, user_id: user_uuid,
      agent_id: agent_uuid, issuer: 'https://demo.example', line_items: line_items,
      total_amount_cents: 1599, currency: 'eur', expires_at: expires_at,
      created_at: expires_at, raw_jws: 'cart-jws'
    )
  end
end

RSpec.shared_context 'with a payment mandate on the trail' do
  include_context 'with a mandate trail to persist'

  let(:payment) do
    Kiosk::Mandate::PaymentMandate.new(
      id: "pay-#{SecureRandom.hex(6)}", cart_mandate_id: cart.id, user_id: user_uuid,
      agent_id: agent_uuid, issuer: 'https://demo.example', payment_method: 'pm_card_visa',
      amount_cents: 1599, currency: 'eur', expires_at: expires_at,
      created_at: expires_at, raw_jws: 'payment-jws'
    )
  end

  let(:settled) { { psp_reference: "pi_#{SecureRandom.hex(4)}", settled_amount_cents: 1599 } }
end

# ── Two spellings of one code are ONE tally and ONE cap (K-1251) ───────
#
# `currency` is a column the ASSISTANT populates from its own signed
# mandate. A tally keyed on the raw bytes would make `"eur"` and `"EUR"` two
# tallies for one currency, and an assistant that alternated the spelling
# between chains would collect the cap TWICE.
#
# Driven against a REAL Postgres because the fold is in the SQL: a
# FakeConnection would assert the text and not the answer. The rows here
# are written with the non-canonical spelling ON PURPOSE — a row already in
# the table from before the boundary canonicalised its input is exactly the
# case the query-side fold exists for.
RSpec.shared_context 'with settlements in several currency spellings' do
  include_context 'with a mandate trail to persist'

  # A whole trail of its own, so two settlements can coexist under
  # `UNIQUE (cart_mandate_id)`.
  def settle(currency:, cents:)
    i = intent.with(id: "intent-#{SecureRandom.hex(6)}", currency: currency)
    c = cart.with(id: "cart-#{SecureRandom.hex(6)}", intent_mandate_id: i.id,
                  currency: currency, total_amount_cents: cents)
    intent_row = executor.send(:persist_intent_mandate, i)
    cart_row   = executor.send(:persist_cart_mandate, c, intent_row_id: intent_row)
    executor.send(:persist_settlement, cart_row_id: cart_row, cart: c,
                                       settled: { psp_reference: "pi_#{SecureRandom.hex(4)}",
                                                  settled_amount_cents: cents })
    c
  end
end

# Concurrent pays of one assistant, half of them declined by the payment
# provider: what settles never passes the cap, and every decline is recorded.
RSpec.shared_context 'with six chains, half declined' do
  include_context 'with a payment mandate on the trail'

  let(:chains) do
    Array.new(6) do |n|
      i = intent.with(id: "intent-#{n}-#{SecureRandom.hex(4)}", raw_jws: "intent-jws-#{n}")
      c = cart.with(id: "cart-#{n}-#{SecureRandom.hex(4)}", intent_mandate_id: i.id, raw_jws: "cart-jws-#{n}",
                    total_amount_cents: 700)
      [i, c, payment.with(id: "pay-#{n}-#{SecureRandom.hex(4)}", cart_mandate_id: c.id, raw_jws: "payment-jws-#{n}")]
    end
  end

  let(:provider) do
    psp = instance_double(Kiosk::PaymentProviders::Base, setup_required?: false)
    allow(psp).to receive(:capture) do |charged, **|
      sleep(0.05)
      raise Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true) if charged.raw_jws.end_with?('0', '2', '4')

      { psp_reference: "pi_#{charged.id}", settled_amount_cents: charged.total_amount_cents }
    end
    psp
  end

  before do
    find = ->(raw_jws:, **) { chains.flatten.find { |m| m.raw_jws == raw_jws } }
    %i[verify_intent verify_cart verify_payment].each { allow(Kiosk::Server::MandateVerifier).to receive(it, &find) }
    Kiosk.configure { |c| (c.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } }) && (c.payment_provider = provider) }
  end
end

RSpec.shared_context 'with two chains of one assistant' do
  include_context 'with a payment mandate on the trail'

  let(:chains) do
    Array.new(2) do |n|
      i = intent.with(id: "intent-#{n}-#{SecureRandom.hex(4)}", raw_jws: "intent-jws-#{n}")
      c = cart.with(id: "cart-#{n}-#{SecureRandom.hex(4)}", intent_mandate_id: i.id, raw_jws: "cart-jws-#{n}")
      [i, c, payment.with(id: "pay-#{n}-#{SecureRandom.hex(4)}", cart_mandate_id: c.id, raw_jws: "payment-jws-#{n}")]
    end
  end

  before do
    mandates = chains.flatten
    find = ->(raw_jws:, **) { mandates.find { |m| m.raw_jws == raw_jws } }
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent, &find)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart, &find)
    # Between the cap check and the cart insert: the window two pays race in.
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment) do |**kw|
      sleep(0.3)
      find.call(**kw)
    end
    Kiosk.configure do |c|
      c.spending_cap     = ->(**) { { amount_cents: 2000, currency: 'eur' } }
      c.payment_provider = instance_double(Kiosk::PaymentProviders::Base, setup_required?: false, capture: settled)
    end
  end
end

# ── The settled replay (K-850), driven end to end ──────────────────────
#
# WHY IT IS HERE and not only in executor_spec.rb. The whole behaviour is a
# LOOKUP: one statement that joins settlements to the three mandate tables
# and compares the stored `raw_jws` of each against the bytes presented
# now. A FakeConnection cannot tell you whether that join resolves, whether
# the FK columns line up, or whether a uuid bind matches — only a real
# Postgres can, which is this file's entire reason to exist. The unique
# violation that reaches the rescue here is a REAL one, raised by the real
# `UNIQUE (user_id, mandate_id)` in the shipped migration SQL.
#
# THE DECISION (2026-08-21, ADR-0026): a `pay` replaying an
# already-SETTLED cart is IDEMPOTENT — it returns the settlement the first
# call returned. A re-presented chain that was never captured, or whose
# capture is still in flight, keeps `409 conflict` before any capture.
RSpec.shared_context 'with a replayed pay against real Postgres' do
  include_context 'with a payment mandate on the trail'
  include ExecutorPersistenceSpec::Replay

  let(:captures) { [] }
  let(:provider) do
    psp = instance_double(Kiosk::Server::PaymentClaim)
    allow(psp).to receive(:setup_required?).and_return(false)
    # The PSP keys a capture by the cart id: a second capture of one cart answers the first.
    %i[capture resume].each do |call|
      allow(psp).to receive(call) do |charged, **_kwargs|
        captures << charged.id
        { psp_reference: "pi_#{charged.id}", settled_amount_cents: charged.total_amount_cents }
      end
    end
    psp
  end

  let(:args) do
    { intent_mandate_jws: intent.raw_jws,
      cart_mandate_jws: cart.raw_jws,
      payment_mandate_jws: payment.raw_jws }
  end

  before do
    Kiosk.configuration.payment_provider = provider
    allow(Kiosk::Server::MandateVerifier).to receive_messages(verify_intent: intent, verify_cart: cart, verify_payment: payment)
  end
end

RSpec.describe Kiosk::Server::Executor do
  # The helpers are private — they are the Executor's own persistence, not a
  # public seam — so the spec reaches them the only way there is.
  describe '#persist_intent_mandate' do
    include_context 'with a payment mandate on the trail'

    it 'returns the SERVER-generated uuid PK and persists every signed field' do
      id  = executor.send(:persist_intent_mandate, intent)
      row = one("SELECT * FROM #{table('intent_mandates')} WHERE id = $1", [id])

      expect(id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(row['mandate_id']).to       eq(intent.id)
      expect(row['user_id']).to          eq(user_uuid)
      expect(row['agent_id']).to         eq(agent_uuid)
      expect(row['issuer']).to           eq('https://demo.example')
      expect(row['scope']).to            eq('groceries')
      expect(row['cap_amount_cents']).to eq(5000)
      expect(row['currency']).to         eq('eur')
      expect(row['raw_jws']).to          eq('intent-jws')
    end

    it 'stores expires_at as the EXACT instant (a zone-dropping coercion lands on another second)' do
      id = executor.send(:persist_intent_mandate, intent)
      epoch = value("SELECT extract(epoch FROM expires_at)::bigint FROM #{table('intent_mandates')} WHERE id = $1", [id])
      expect(epoch.to_i).to eq(expires_at.to_i)
    end
  end

  describe '#persist_intent_mandate column types' do
    include_context 'with a payment mandate on the trail'

    # The uuid columns are the second half of the type story. Postgres'
    # `uuid` type CANONICALISES on input, so an UPPERCASE agent id comes back
    # lower-cased — which a text column, or a value that reached a text
    # column, would not do. And a bind carrying an explicit TEXT type would
    # not reach the row at all: Postgres rejects `uuid = text` outright.
    it 'stores agent_id as a real uuid (canonicalised on input, matchable as ::uuid)' do
      shouted = Kiosk::Mandate::IntentMandate.new(**intent.to_h, agent_id: agent_uuid.upcase)
      id = executor.send(:persist_intent_mandate, shouted)

      expect(value("SELECT agent_id::text FROM #{table('intent_mandates')} WHERE id = $1", [id]))
        .to eq(agent_uuid)
      expect(value("SELECT count(*) FROM #{table('intent_mandates')} WHERE agent_id = $1::uuid", [agent_uuid]).to_i)
        .to eq(1)
    end

    it 'rejects a non-uuid agent_id at the database rather than storing it as text' do
      bogus = Kiosk::Mandate::IntentMandate.new(**intent.to_h, agent_id: 'not-a-uuid')
      expect { executor.send(:persist_intent_mandate, bogus) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe '#persist_intent_mandate hostile input' do
    include_context 'with a payment mandate on the trail'

    # The whole point of the row (K-654): values are DATA, never SQL. This
    # passes under `connection.quote` too — that is what makes it the
    # regression guard rather than the proof of the conversion.
    it 'round-trips a SQL-injection payload verbatim and leaves the table standing' do
      payload = "'); DROP TABLE #{table('intent_mandates')}; --"
      hostile = Kiosk::Mandate::IntentMandate.new(**intent.to_h, scope: payload, raw_jws: payload)
      id = executor.send(:persist_intent_mandate, hostile)
      row = one("SELECT scope, raw_jws FROM #{table('intent_mandates')} WHERE id = $1", [id])

      expect(row['scope']).to   eq(payload)
      expect(row['raw_jws']).to eq(payload)
      expect(value("SELECT count(*) FROM #{table('intent_mandates')}").to_i).to eq(1)
    end

    it 'raises the unique violation the Executor maps to 409 when the same mandate id is replayed' do
      executor.send(:persist_intent_mandate, intent)
      expect { executor.send(:persist_intent_mandate, intent) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '#persist_cart_mandate' do
    include_context 'with a payment mandate on the trail'

    it 'persists the cart against the SERVER intent id and returns its own server id' do
      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      row = one("SELECT * FROM #{table('cart_mandates')} WHERE id = $1", [cart_row])

      expect(row['intent_mandate_id']).to  eq(intent_row)
      expect(row['mandate_id']).to         eq(cart.id)
      expect(row['total_amount_cents']).to eq(1599)
      expect(row['currency']).to           eq('eur')
    end

    it 'refuses a cart whose intent_mandate_id is not a live intent row (FK, not a pre-check)' do
      expect { executor.send(:persist_cart_mandate, cart, intent_row_id: SecureRandom.uuid) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe '#persist_cart_mandate line_items' do
    include_context 'with a payment mandate on the trail'

    def containing_count(cart_row, items)
      value(
        "SELECT count(*) FROM #{table('cart_mandates')} WHERE id = $1 AND line_items @> $2::jsonb",
        [cart_row, items.to_json]
      ).to_i
    end

    # ── THE TYPE ASSERTION THIS FILE EXISTS FOR ──────────────────────────
    #
    # `line_items` is `jsonb NOT NULL`, and the value handed to the insert is
    # JSON *text* (`cart.line_items.to_json`). It must land as a jsonb ARRAY.
    # A bind that coerced the argument to a json STRING — one extra
    # `to_json`, or a String-typed bind attribute against a `to_jsonb()`
    # style cast — stores the scalar `"[{\"sku\":\"pizza\"…}]"` instead:
    # `jsonb_typeof` answers "string", every `->`/`->>` answers NULL, and
    # every `line_items @> '[…]'::jsonb` containment answers FALSE. That last
    # one is the shape the demos' replace-guard (K-544) and the K-545
    # pay-race fix are written against, so it is asserted here directly even
    # though no containment predicate lives in kiosk-server itself.
    it 'stores line_items as a jsonb ARRAY that satisfies @> containment (NOT a json string)' do
      _intent_row, cart_row = persist_trail

      expect(value("SELECT jsonb_typeof(line_items) FROM #{table('cart_mandates')} WHERE id = $1", [cart_row]))
        .to eq('array')
      expect(value("SELECT line_items -> 0 ->> 'sku' FROM #{table('cart_mandates')} WHERE id = $1", [cart_row]))
        .to eq('pizza')
      expect(containing_count(cart_row, [{ 'sku' => 'pizza', 'qty' => 2 }])).to eq(1)
      expect(containing_count(cart_row, [{ 'sku' => 'caviar' }])).to eq(0)
    end
  end

  describe '#persist_payment_mandate' do
    include_context 'with a payment mandate on the trail'

    it 'persists the signed payment mandate against the SERVER cart id' do
      _intent_row, cart_row = persist_trail
      row = one("SELECT * FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row])

      expect(row['mandate_id']).to     eq(payment.id)
      expect(row['payment_method']).to eq('pm_card_visa')
      expect(row['amount_cents']).to   eq(1599)
      expect(row['raw_jws']).to        eq('payment-jws')
    end

    it "persists the 'on_file' sentinel when the mandate presents no payment_method" do
      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      on_file    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, payment_method: '')
      executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: on_file)

      expect(value("SELECT payment_method FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row]))
        .to eq('on_file')
    end
  end

  describe '#persist_payment_mandate expiry' do
    include_context 'with a payment mandate on the trail'

    it 'persists a NULL expires_at when the mandate carries none (the column is nullable here)' do
      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      undated    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, expires_at: nil)
      executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: undated)

      expect(value("SELECT expires_at FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row]))
        .to be_nil
    end
  end

  describe '#persist_settlement' do
    include_context 'with a payment mandate on the trail'

    it 'records the receipt against the SERVER cart id and returns its server id' do
      _intent_row, cart_row = persist_trail
      settlement_id = executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
      row = one("SELECT * FROM #{table('settlements')} WHERE id = $1", [settlement_id])

      expect(row['cart_mandate_id']).to      eq(cart_row)
      expect(row['user_id']).to              eq(user_uuid)
      expect(row['agent_id']).to             eq(agent_uuid)
      expect(row['psp_reference']).to        eq(settled[:psp_reference])
      expect(row['settled_amount_cents']).to eq(1599)
      expect(row['currency']).to             eq('eur')
      expect(row['settled_at']).not_to be_nil
      # Server-minted receipt: no agent JWS to carry, so the table has no
      # column to carry one in (K-948). Asserted on the ROW's keys rather
      # than on a value, because the previous shape of this assertion —
      # `row["raw_jws"] == ""` — is exactly what a dropped column would also
      # satisfy if it were read as a missing key coerced to nil.
      expect(row.keys).not_to include('raw_jws')
    end

    it 'enforces one settlement per cart (UNIQUE (cart_mandate_id))' do
      _intent_row, cart_row = persist_trail
      executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
      expect { executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '#spent_in_window over settlements' do
    include_context 'with a payment mandate on the trail'

    before do
      _intent_row, cart_row = persist_trail
      executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
    end

    it "sums this agent's settlements in the given currency" do
      expect(settled_total(currency: 'eur')).to eq(1599)
    end

    it 'is currency-scoped (K-551): a different currency tallies zero' do
      expect(settled_total(currency: 'usd')).to eq(0)
    end

    it "is agent-scoped: another assistant's spend is not counted" do
      expect(settled_total(agent_id: SecureRandom.uuid, currency: 'eur')).to eq(0)
    end

    it 'counts a settlement inside the rolling window' do
      expect(settled_total(window_days: 7, currency: 'eur')).to eq(1599)
    end

    it 'excludes a settlement older than the rolling window' do
      connection.exec_query(
        "UPDATE #{table('settlements')} SET settled_at = now() - INTERVAL '9 days'", 'persist spec'
      )
      expect(settled_total(window_days: 7, currency: 'eur')).to eq(0)
    end
  end

  describe 'spelling is not identity (K-1251)' do
    include_context 'with settlements in several currency spellings'

    it 'tallies an EUR settlement under eur' do
      settle(currency: 'EUR', cents: 2500)
      expect(settled_total(currency: 'eur')).to eq(2500)
    end

    it "tallies a padded ' EUR ' settlement under eur" do
      settle(currency: ' EUR ', cents: 700)
      expect(settled_total(currency: 'eur')).to eq(700)
    end

    it 'sums both spellings into ONE tally' do
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'EUR', cents: 2500)
      expect(settled_total(currency: 'eur')).to eq(5500)
    end

    it 'canonicalises the ASKED currency too, so an EUR cart reads the eur history' do
      settle(currency: 'eur', cents: 3000)
      expect(settled_total(currency: 'EUR')).to eq(3000)
    end

    # The positive control: folding CASE must not fold two different codes.
    it 'still keeps usd out of the eur tally' do
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'USD', cents: 4000)
      expect(settled_total(currency: 'eur')).to eq(3000)
      expect(settled_total(currency: 'usd')).to eq(4000)
    end
  end

  describe 'spending cap across spellings' do
    include_context 'with settlements in several currency spellings'

    # THE ONE THE ROW IS ABOUT: spend under one spelling, then the other,
    # against a single configured cap. Pre-fix the second charge saw a tally
    # of 3000 against a 5000 cap and went through; the assistant had spent
    # 5500 under a cap of 5000.
    it 'hits ONE cap across both spellings' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'EUR', cents: 2500)

      over = cart.with(id: "cart-#{SecureRandom.hex(6)}", currency: 'eur',
                       total_amount_cents: 1)
      expect { executor.send(:enforce_spending_cap!, over) }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded)
    end

    it 'still admits a charge that fits under the combined tally' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'EUR', cents: 1000)

      ok = cart.with(id: "cart-#{SecureRandom.hex(6)}", currency: 'EUR',
                     total_amount_cents: 900)
      expect { executor.send(:enforce_spending_cap!, ok) }.not_to raise_error
    end
  end

  # A cart whose capture may still be running counts against the cap, and two
  # concurrent pays of one assistant are serialised, so neither can miss the other.
  describe 'spending cap and carts in flight' do
    include_context 'with a payment mandate on the trail'

    before { Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } } }

    def another_cart(cents) = cart.with(id: "cart-#{SecureRandom.hex(6)}", total_amount_cents: cents)

    it 'counts a persisted cart with no settlement yet' do
      persist_trail
      expect { executor.send(:enforce_spending_cap!, another_cart(500)) }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e| expect(e.hint).to include('1599 already settled or in flight') }
    end

    it 'stops counting an unsettled cart once its mandate has expired' do
      persist_trail
      connection.exec_query("UPDATE #{table('cart_mandates')} SET expires_at = now() - INTERVAL '1 minute'", 'persist spec')
      expect { executor.send(:enforce_spending_cap!, another_cart(500)) }.not_to raise_error
    end

    it 'stops counting a declined cart at once' do
      _, cart_row = persist_trail
      executor.send(:decline_cart, cart_row)
      expect { executor.send(:enforce_spending_cap!, another_cart(500)) }.not_to raise_error
    end

    it 'does not count a repeat of a recorded cart a second time' do
      persist_trail
      expect { executor.send(:enforce_spending_cap!, cart) }.not_to raise_error
    end
  end

  # A refund gives the cap back: the cap counts a settlement less what was refunded of it.
  describe 'spending cap and refunds' do
    include_context 'with a payment mandate on the trail'

    before { Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } } }

    let(:settlement_id) do
      _, cart_row = persist_trail
      executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
    end

    def refund(cents)
      connection.exec_query(
        "INSERT INTO #{table('refunds')} (settlement_id, psp_reference, refunded_amount_cents, refunded_at) " \
        'VALUES ($1, $2, $3, now())', 'persist spec', [settlement_id, "re_#{SecureRandom.hex(4)}", cents]
      )
    end

    def another_cart(cents) = cart.with(id: "cart-#{SecureRandom.hex(6)}", total_amount_cents: cents)

    it 'counts a settlement less what was refunded of it' do
      refund(600)
      expect(settled_total(currency: 'eur')).to eq(999)
    end

    it 'admits a charge that fits only because of a refund' do
      refund(1000)
      expect { executor.send(:enforce_spending_cap!, another_cart(1000)) }.not_to raise_error
    end

    it 'counts a settlement refunded past its amount as zero' do
      2.times { refund(1000) }
      expect(settled_total(currency: 'eur')).to eq(0)
    end
  end

  describe 'concurrent pays with declines under one cap' do
    include_context 'with six chains, half declined'

    def pay_in_a_thread(intent, cart, payment)
      args = { intent_mandate_jws: intent.raw_jws, cart_mandate_jws: cart.raw_jws, payment_mandate_jws: payment.raw_jws }
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          described_class.call(kind: :pay, args: args, identity: identity, connection: conn) && :paid
        rescue Kiosk::Server::Errors::SpendingCapExceeded
          :refused
        rescue Kiosk::Server::Errors::PaymentFailed
          :declined
        end
      end
    end

    it 'never settles past the cap, and leaves no declined cart in flight' do
      results = chains.map { |chain| pay_in_a_thread(*chain) }.map(&:value)

      settled = value("SELECT COALESCE(SUM(settled_amount_cents), 0) FROM #{table('settlements')}").to_i
      expect(settled).to be <= 2000
      expect(settled_total(currency: 'eur')).to eq(settled) # nothing in flight
      expect(value("SELECT count(*) FROM #{table('cart_mandates')} WHERE declined_at IS NOT NULL").to_i)
        .to eq(results.count(:declined))
    end
  end

  describe 'two concurrent pays under one cap' do
    include_context 'with two chains of one assistant'

    def pay_in_a_thread(intent, cart, payment)
      args = { intent_mandate_jws: intent.raw_jws, cart_mandate_jws: cart.raw_jws, payment_mandate_jws: payment.raw_jws }
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          described_class.call(kind: :pay, args: args, identity: identity, connection: conn) && :paid
        rescue Kiosk::Server::Errors::SpendingCapExceeded
          :refused
        end
      end
    end

    it 'lets one through when each fits the cap alone and the two together do not' do
      results = chains.map { |chain| pay_in_a_thread(*chain) }.map(&:value)
      expect(results.sort).to eq(%i[paid refused])
    end
  end

  describe 'a replayed pay of a settled chain' do
    include_context 'with a replayed pay against real Postgres'

    # THE PIN THE DECISION ASKED FOR: one capture, one settlement row, and
    # the SECOND call returns the FIRST call's answer field for field.
    it 'answers the identical chain with the ORIGINAL settlement, and captures exactly once' do
      first = pay
      second = pay

      expect(second.kind).to eq(:value)
      expect(second.payload).to eq(first.payload)
      expect(second.payload[:psp_reference]).to eq("pi_#{cart.id}")
      expect(captures).to eq([cart.id])   # NOT charged a second time
      expect(settlement_count).to eq(1)   # NO second settlement minted
    end

    # The operator's work after the payment reads the settlement, so the
    # provider hears of it only once the row exists, and once.
    it 'tells the provider the cart is settled after the settlement row is written, and not on the replay' do
      seen = []
      allow(provider).to receive(:settled) { |settled_cart| seen << [settled_cart.id, settlement_count] }

      2.times { pay }

      expect(seen).to eq([[cart.id, 1]])
    end

    # The replay is answered from the STORED row, so the settlement id it
    # hands back is the one the settlements table holds — not a fresh one.
    it 'returns the stored settlement row, not a reconstruction' do
      first = pay
      stored = one("SELECT * FROM #{table('settlements')}")

      expect(first.payload[:settlement_id]).to eq(stored['id'])
      expect(pay.payload[:settlement_id]).to eq(stored['id'])
    end
  end

  describe 'a repeated pay of an unfinished chain' do
    include_context 'with a replayed pay against real Postgres'

    # The trail is persisted and nothing was captured: the call stopped before
    # the capture. The repeat captures and settles.
    it 'captures and settles a chain that was persisted but never captured' do
      persist_trail

      expect(pay.payload).to include(psp_reference: "pi_#{cart.id}", settled_amount_cents: 1599)
      expect(captures).to eq([cart.id])
      expect(settlement_count).to eq(1)
    end

    # The capture returned and phase 3 never committed. The repeat charges again
    # under the same cart id, which the PSP answers with the first charge, and
    # writes the missing settlement.
    it 'settles a chain whose capture ran but whose settlement was never written' do
      allow(described_class).to receive(:new).and_return(executor)
      allow(executor).to receive(:persist_settlement)
        .and_raise(StandardError, 'connection reset during settlement insert')
      expect { pay }.to raise_error(StandardError, /connection reset/)
      expect(settlement_count).to eq(0)

      allow(executor).to receive(:persist_settlement).and_call_original
      expect(pay.payload[:psp_reference]).to eq("pi_#{cart.id}")
      expect(captures).to eq([cart.id, cart.id])
      expect(settlement_count).to eq(1)
      expect(pay.payload[:psp_reference]).to eq("pi_#{cart.id}")
      expect(captures).to eq([cart.id, cart.id])
    end
  end

  describe 'a repeated pay of an unfinished chain, concurrent or declined' do
    include_context 'with a replayed pay against real Postgres'

    it 'answers two concurrent repeats with one settlement' do
      persist_trail
      results = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            described_class.call(kind: :pay, args: args, identity: identity, connection: conn).payload
          end
        end
      end.map(&:value)

      expect(results.pluck(:settlement_id).uniq.size).to eq(1)
      expect(settlement_count).to eq(1)
    end

    it 'answers 409 conflict to a repeat of a declined chain, before any capture' do
      allow(provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
        expect(e.http_status).to eq(409)
      }
      expect(provider).not_to have_received(:resume)
      expect(settlement_count).to eq(0)
    end
  end

  describe 'a repeated pay after an unknown outcome' do
    include_context 'with a replayed pay against real Postgres'

    it 'keeps an unknown outcome open: the repeat charges again under the same key' do
      allow(provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('unknown', retryable: false))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e| expect(e.hint).to include('SAME chain') }

      expect(pay.payload[:psp_reference]).to eq("pi_#{cart.id}")
      expect(settlement_count).to eq(1)
    end
  end

  describe 'a replayed pay that is not the same request' do
    include_context 'with a replayed pay against real Postgres'

    # A MANDATE ID RE-USED WITH DIFFERENT CONTENT IS NOT A REPLAY. The cart
    # `id` is the settled one, the signed bytes are not — so the settlement
    # this principal already has must NOT be handed to it as the answer to a
    # different request. The `raw_jws` equality in the lookup is what says so.
    it 'refuses to hand the settlement to a chain whose bytes differ (same id, new content)' do
      pay
      forged = Kiosk::Mandate::CartMandate.new(**cart.to_h, raw_jws: 'cart-jws-TAMPERED')
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(forged)

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
      expect(captures).to eq([cart.id])
      expect(settlement_count).to eq(1)
    end

    # And the lookup is scoped to the acting principal on every mandate row:
    # another assistant's user_id sees no settlement of this one's.
    it "does not answer a DIFFERENT principal with this principal's settlement" do
      pay
      stranger = build_identity(user_id: SecureRandom.uuid, agent_id: SecureRandom.uuid)
      chain = described_class::Chain.new(intent, cart, payment)
      expect(described_class.new(connection: connection, identity: stranger).send(:chain_record, chain)).to be_nil
    end
  end
end
