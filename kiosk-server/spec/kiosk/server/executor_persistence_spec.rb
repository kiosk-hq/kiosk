# frozen_string_literal: true

require 'active_record'
require 'securerandom'

# The three `persist_*` helpers — plus `spent_in_window` — against a REAL
# Postgres.
#
# WHY THIS FILE EXISTS. Everywhere else the Executor is driven through
# `FakeConnection`, which records SQL as a string and asserts nothing about
# what a database would do with it; `executor_spec.rb` STUBS the three persist
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

    # Persist the checkout and payment mandates; returns the checkout row id.
    def persist_trail(checkout_mandate = checkout, payment_mandate = payment)
      checkout_row = executor.send(:persist_checkout_mandate, checkout_mandate)
      executor.send(:persist_payment_mandate, checkout_row_id: checkout_row, payment: payment_mandate)
      checkout_row
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

  let(:line_items) { [{ 'sku' => 'pizza', 'qty' => 2 }, { 'sku' => 'cola', 'qty' => 1 }] }

  let(:checkout) do
    Kiosk::Mandate::CheckoutMandate.new(
      reference: "cm-#{SecureRandom.hex(6)}", checkout_hash: "hash-#{SecureRandom.hex(6)}", user_id: user_uuid,
      agent_id: agent_uuid, issuer: 'https://demo.example', line_items: line_items,
      total_amount_cents: 1599, currency: 'eur', expires_at: expires_at, sd_jwt: 'checkout-sd-jwt'
    )
  end
end

RSpec.shared_context 'with a payment mandate on the trail' do
  include_context 'with a mandate trail to persist'

  let(:payment) do
    Kiosk::Mandate::PaymentMandate.new(
      reference: "pm-#{SecureRandom.hex(6)}", transaction_id: checkout.checkout_hash, user_id: user_uuid,
      agent_id: agent_uuid, issuer: 'https://demo.example', payment_instrument: 'pm_card_visa',
      amount_cents: 1599, currency: 'eur', expires_at: expires_at, sd_jwt: 'payment-sd-jwt'
    )
  end

  let(:settled) { { psp_reference: "pi_#{SecureRandom.hex(4)}", settled_amount_cents: 1599 } }

  # Another checkout, or another pair for `checkout_hash`: new references, new bytes.
  def another_checkout(tag = SecureRandom.hex(4), checkout_hash: "hash-#{tag}", **changes)
    checkout.with(reference: "cm-#{tag}", checkout_hash:, sd_jwt: "checkout-sd-jwt-#{tag}", **changes)
  end

  def payment_for(checkout_mandate, tag)
    payment.with(reference: "pm-#{tag}", transaction_id: checkout_mandate.checkout_hash, sd_jwt: "payment-sd-jwt-#{tag}")
  end

  # The verifier answers whichever mandate carries the presented bytes.
  def verify_from(mandates, delay: 0)
    find = ->(sd_jwt:, **) { mandates.find { |m| m.sd_jwt == sd_jwt } }
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_checkout, &find)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment) do |**kw|
      sleep(delay)
      find.call(**kw)
    end
  end

  def pay_args(checkout_mandate, payment_mandate) = { checkout_mandate: checkout_mandate.sd_jwt, payment_mandate: payment_mandate.sd_jwt }
end

# ── Two spellings of one code are ONE tally and ONE cap (K-1251) ───────
#
# A tally keyed on the raw bytes would make `"eur"` and `"EUR"` two tallies
# for one currency, and an assistant that alternated the spelling between
# pairs would collect the cap TWICE.
#
# Driven against a REAL Postgres because the fold is in the SQL: a
# FakeConnection would assert the text and not the answer. The rows here
# are written with the non-canonical spelling ON PURPOSE — a row already in
# the table from before the boundary canonicalised its input is exactly the
# case the query-side fold exists for.
RSpec.shared_context 'with settlements in several currency spellings' do
  include_context 'with a payment mandate on the trail'

  # A checkout mandate of its own, so two settlements can coexist under
  # `UNIQUE (checkout_mandate_id)`.
  def settle(currency:, cents:)
    c = another_checkout(currency:, total_amount_cents: cents)
    checkout_row = executor.send(:persist_checkout_mandate, c)
    executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: c,
                                       settled: { psp_reference: "pi_#{SecureRandom.hex(4)}",
                                                  settled_amount_cents: cents })
    c
  end
end

# Concurrent pays of one assistant, half of them declined by the payment
# provider: what settles never passes the cap, and every decline is recorded.
RSpec.shared_context 'with six pairs, half declined' do
  include_context 'with a payment mandate on the trail'

  let(:pairs) do
    Array.new(6) do |n|
      c = another_checkout(n, total_amount_cents: 700)
      [c, payment_for(c, n)]
    end
  end

  let(:provider) do
    psp = instance_double(Kiosk::PaymentProviders::Base, setup_required?: false)
    allow(psp).to receive(:capture) do |charged, **|
      sleep(0.05)
      raise Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true) if charged.sd_jwt.end_with?('0', '2', '4')

      { psp_reference: "pi_#{charged.reference}", settled_amount_cents: charged.total_amount_cents }
    end
    psp
  end

  before do
    verify_from(pairs.flatten)
    Kiosk.configure { |c| (c.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } }) && (c.payment_provider = provider) }
  end
end

RSpec.shared_context 'with two pairs of one assistant' do
  include_context 'with a payment mandate on the trail'

  let(:pairs) do
    Array.new(2) do |n|
      c = another_checkout(n)
      [c, payment_for(c, n)]
    end
  end

  before do
    # Between the cap check and the checkout insert: the window two pays race in.
    verify_from(pairs.flatten, delay: 0.3)
    Kiosk.configure do |c|
      c.spending_cap     = ->(**) { { amount_cents: 2000, currency: 'eur' } }
      c.payment_provider = instance_double(Kiosk::PaymentProviders::Base, setup_required?: false, capture: settled)
    end
  end
end

# ── The settled replay (K-850), driven end to end ──────────────────────
#
# WHY IT IS HERE and not only in executor_spec.rb. The whole behaviour is a
# LOOKUP: one statement that joins settlements to the two mandate tables
# and compares the stored `sd_jwt` of each against the bytes presented now.
# A FakeConnection cannot tell you whether that join resolves, whether the
# FK columns line up, or whether a uuid bind matches — only a real Postgres
# can. The unique violation that reaches the rescue here is a REAL one,
# raised by the unique keys in the shipped migration SQL.
#
# THE DECISION (2026-08-21, ADR-0026): a `pay` replaying an already-SETTLED
# pair is IDEMPOTENT — it returns the settlement the first call returned. A
# re-presented pair that was never captured, or whose capture is still in
# flight, keeps `409 conflict` before any capture.
RSpec.shared_context 'with a replayed pay against real Postgres' do
  include_context 'with a payment mandate on the trail'
  include ExecutorPersistenceSpec::Replay

  let(:captures) { [] }
  let(:provider) do
    psp = instance_double(Kiosk::Server::PaymentClaim)
    allow(psp).to receive(:setup_required?).and_return(false)
    # The PSP keys a capture by the checkout mandate reference: a second capture of one answers the first.
    %i[capture resume].each do |call|
      allow(psp).to receive(call) do |charged, **_kwargs|
        captures << charged.reference
        { psp_reference: "pi_#{charged.reference}", settled_amount_cents: charged.total_amount_cents }
      end
    end
    psp
  end

  let(:args) { pay_args(checkout, payment) }

  before do
    Kiosk.configuration.payment_provider = provider
    allow(Kiosk::Server::MandateVerifier).to receive_messages(verify_checkout: checkout, verify_payment: payment)
  end
end

RSpec.describe Kiosk::Server::Executor do
  # The helpers are private — they are the Executor's own persistence, not a
  # public seam — so the spec reaches them the only way there is.
  describe '#persist_checkout_mandate' do
    include_context 'with a payment mandate on the trail'

    it 'returns the SERVER-generated uuid PK and persists every field' do
      id  = executor.send(:persist_checkout_mandate, checkout)
      row = one("SELECT * FROM #{table('checkout_mandates')} WHERE id = $1", [id])

      expect(id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(row).to include('reference' => checkout.reference, 'checkout_hash' => checkout.checkout_hash,
                             'user_id' => user_uuid, 'agent_id' => agent_uuid, 'issuer' => 'https://demo.example',
                             'total_amount_cents' => 1599, 'currency' => 'eur', 'sd_jwt' => 'checkout-sd-jwt')
    end

    it 'stores expires_at as the EXACT instant (a zone-dropping coercion lands on another second)' do
      id = executor.send(:persist_checkout_mandate, checkout)
      epoch = value("SELECT extract(epoch FROM expires_at)::bigint FROM #{table('checkout_mandates')} WHERE id = $1", [id])
      expect(epoch.to_i).to eq(expires_at.to_i)
    end
  end

  describe '#persist_checkout_mandate column types' do
    include_context 'with a payment mandate on the trail'

    # The uuid columns are the second half of the type story. Postgres'
    # `uuid` type CANONICALISES on input, so an UPPERCASE agent id comes back
    # lower-cased — which a text column would not do. And a bind carrying an
    # explicit TEXT type would not reach the row at all.
    it 'stores agent_id as a real uuid (canonicalised on input, matchable as ::uuid)' do
      id = executor.send(:persist_checkout_mandate, checkout.with(agent_id: agent_uuid.upcase))

      expect(value("SELECT agent_id::text FROM #{table('checkout_mandates')} WHERE id = $1", [id]))
        .to eq(agent_uuid)
      expect(value("SELECT count(*) FROM #{table('checkout_mandates')} WHERE agent_id = $1::uuid", [agent_uuid]).to_i)
        .to eq(1)
    end

    it 'rejects a non-uuid agent_id at the database rather than storing it as text' do
      expect { executor.send(:persist_checkout_mandate, checkout.with(agent_id: 'not-a-uuid')) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe '#persist_checkout_mandate hostile input and unique keys' do
    include_context 'with a payment mandate on the trail'

    # The whole point of the row (K-654): values are DATA, never SQL.
    it 'round-trips a SQL-injection payload verbatim and leaves the table standing' do
      payload = "'); DROP TABLE #{table('checkout_mandates')}; --"
      id = executor.send(:persist_checkout_mandate, checkout.with(sd_jwt: payload))

      expect(value("SELECT sd_jwt FROM #{table('checkout_mandates')} WHERE id = $1", [id])).to eq(payload)
      expect(value("SELECT count(*) FROM #{table('checkout_mandates')}").to_i).to eq(1)
    end

    it 'raises the unique violation the Executor maps to 409 when the same reference is replayed' do
      executor.send(:persist_checkout_mandate, checkout)
      expect { executor.send(:persist_checkout_mandate, checkout) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'holds one live checkout mandate per checkout, and frees the checkout on a decline' do
      row = executor.send(:persist_checkout_mandate, checkout)
      second = another_checkout(checkout_hash: checkout.checkout_hash)
      expect { executor.send(:persist_checkout_mandate, second) }.to raise_error(ActiveRecord::RecordNotUnique)

      executor.send(:decline_checkout, row)
      expect(executor.send(:persist_checkout_mandate, second)).to be_a(String)
    end
  end

  describe '#persist_checkout_mandate line_items' do
    include_context 'with a payment mandate on the trail'

    def containing_count(checkout_row, items)
      value(
        "SELECT count(*) FROM #{table('checkout_mandates')} WHERE id = $1 AND line_items @> $2::jsonb",
        [checkout_row, items.to_json]
      ).to_i
    end

    # ── THE TYPE ASSERTION THIS FILE EXISTS FOR ──────────────────────────
    #
    # `line_items` is `jsonb NOT NULL`, and the value handed to the insert is
    # JSON *text*. It must land as a jsonb ARRAY. A bind that coerced the
    # argument to a json STRING stores a scalar instead: `jsonb_typeof`
    # answers "string", and every `line_items @> '[…]'::jsonb` containment
    # answers FALSE — the shape `Kiosk::CheckoutMandate.referencing` reads.
    it 'stores line_items as a jsonb ARRAY that satisfies @> containment (NOT a json string)' do
      checkout_row = persist_trail

      expect(value("SELECT jsonb_typeof(line_items) FROM #{table('checkout_mandates')} WHERE id = $1", [checkout_row]))
        .to eq('array')
      expect(value("SELECT line_items -> 0 ->> 'sku' FROM #{table('checkout_mandates')} WHERE id = $1", [checkout_row]))
        .to eq('pizza')
      expect(containing_count(checkout_row, [{ 'sku' => 'pizza', 'qty' => 2 }])).to eq(1)
      expect(containing_count(checkout_row, [{ 'sku' => 'caviar' }])).to eq(0)
    end
  end

  describe '#persist_payment_mandate' do
    include_context 'with a payment mandate on the trail'

    it 'persists the signed payment mandate against the SERVER checkout id' do
      checkout_row = persist_trail
      row = one("SELECT * FROM #{table('payment_mandates')} WHERE checkout_mandate_id = $1", [checkout_row])

      expect(row).to include('reference' => payment.reference, 'payment_instrument' => 'pm_card_visa',
                             'amount_cents' => 1599, 'sd_jwt' => 'payment-sd-jwt')
    end

    it 'refuses a payment mandate whose checkout_mandate_id is not a live row (FK, not a pre-check)' do
      expect { executor.send(:persist_payment_mandate, checkout_row_id: SecureRandom.uuid, payment: payment) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe '#persist_settlement' do
    include_context 'with a payment mandate on the trail'

    it 'records the receipt against the SERVER checkout id and returns its server id' do
      checkout_row = persist_trail
      settlement_id = executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: checkout, settled: settled)
      row = one("SELECT * FROM #{table('settlements')} WHERE id = $1", [settlement_id])

      expect(row).to include('checkout_mandate_id' => checkout_row, 'user_id' => user_uuid, 'agent_id' => agent_uuid,
                             'psp_reference' => settled[:psp_reference], 'settled_amount_cents' => 1599, 'currency' => 'eur')
      expect(row['settled_at']).not_to be_nil
      # Server-minted receipt: nobody signs it, so the table has no column for a signature.
      expect(row.keys).not_to include('sd_jwt')
    end

    it 'enforces one settlement per checkout mandate (UNIQUE (checkout_mandate_id))' do
      checkout_row = persist_trail
      executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: checkout, settled: settled)
      expect { executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: checkout, settled: settled) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '#spent_in_window over settlements' do
    include_context 'with a payment mandate on the trail'

    before do
      checkout_row = persist_trail
      executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: checkout, settled: settled)
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

    it 'canonicalises the ASKED currency too, so an EUR checkout reads the eur history' do
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

    # Spend under one spelling, then the other, against a single configured
    # cap: the second charge must see the whole tally.
    it 'hits ONE cap across both spellings' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'EUR', cents: 2500)

      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 1)) }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded)
    end

    it 'still admits a charge that fits under the combined tally' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      settle(currency: 'eur', cents: 3000)
      settle(currency: 'EUR', cents: 1000)

      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 900)) }.not_to raise_error
    end
  end

  # A checkout whose capture may still be running counts against the cap, and
  # two concurrent pays of one assistant are serialised, so neither can miss the other.
  describe 'spending cap and checkouts in flight' do
    include_context 'with a payment mandate on the trail'

    before { Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } } }

    it 'counts a persisted checkout mandate with no settlement yet' do
      persist_trail
      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 500)) }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e| expect(e.hint).to include('1599 already settled or in flight') }
    end

    it 'stops counting an unsettled checkout mandate once it has expired' do
      persist_trail
      connection.exec_query("UPDATE #{table('checkout_mandates')} SET expires_at = now() - INTERVAL '1 minute'", 'persist spec')
      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 500)) }.not_to raise_error
    end

    it 'stops counting a declined checkout mandate at once' do
      executor.send(:decline_checkout, persist_trail)
      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 500)) }.not_to raise_error
    end

    it 'does not count a repeat of a recorded checkout mandate a second time' do
      persist_trail
      expect { executor.send(:enforce_spending_cap!, checkout) }.not_to raise_error
    end
  end

  # A refund gives the cap back: the cap counts a settlement less what was refunded of it.
  describe 'spending cap and refunds' do
    include_context 'with a payment mandate on the trail'

    before { Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } } }

    let(:settlement_id) do
      executor.send(:persist_settlement, checkout_row_id: persist_trail, checkout: checkout, settled: settled)
    end

    def refund(cents)
      connection.exec_query(
        "INSERT INTO #{table('refunds')} (settlement_id, psp_reference, refunded_amount_cents, refunded_at) " \
        'VALUES ($1, $2, $3, now())', 'persist spec', [settlement_id, "re_#{SecureRandom.hex(4)}", cents]
      )
    end

    it 'counts a settlement less what was refunded of it' do
      refund(600)
      expect(settled_total(currency: 'eur')).to eq(999)
    end

    it 'admits a charge that fits only because of a refund' do
      refund(1000)
      expect { executor.send(:enforce_spending_cap!, another_checkout(total_amount_cents: 1000)) }.not_to raise_error
    end

    it 'counts a settlement refunded past its amount as zero' do
      2.times { refund(1000) }
      expect(settled_total(currency: 'eur')).to eq(0)
    end
  end

  describe 'concurrent pays with declines under one cap' do
    include_context 'with six pairs, half declined'

    def pay_in_a_thread(checkout_mandate, payment_mandate)
      args = pay_args(checkout_mandate, payment_mandate)
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

    it 'never settles past the cap, and leaves no declined checkout in flight' do
      results = pairs.map { |pair| pay_in_a_thread(*pair) }.map(&:value)

      settled = value("SELECT COALESCE(SUM(settled_amount_cents), 0) FROM #{table('settlements')}").to_i
      expect(settled).to be <= 2000
      expect(settled_total(currency: 'eur')).to eq(settled) # nothing in flight
      expect(value("SELECT count(*) FROM #{table('checkout_mandates')} WHERE declined_at IS NOT NULL").to_i)
        .to eq(results.count(:declined))
    end
  end

  describe 'two concurrent pays under one cap' do
    include_context 'with two pairs of one assistant'

    def pay_in_a_thread(checkout_mandate, payment_mandate)
      args = pay_args(checkout_mandate, payment_mandate)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          described_class.call(kind: :pay, args: args, identity: identity, connection: conn) && :paid
        rescue Kiosk::Server::Errors::SpendingCapExceeded
          :refused
        end
      end
    end

    it 'lets one through when each fits the cap alone and the two together do not' do
      results = pairs.map { |pair| pay_in_a_thread(*pair) }.map(&:value)
      expect(results.sort).to eq(%i[paid refused])
    end
  end

  describe 'a replayed pay of a settled pair' do
    include_context 'with a replayed pay against real Postgres'

    # One capture, one settlement row, and the SECOND call returns the FIRST
    # call's answer field for field.
    it 'answers the identical pair with the ORIGINAL settlement, and captures exactly once' do
      first = pay
      second = pay

      expect(second.kind).to eq(:value)
      expect(second.payload).to eq(first.payload)
      expect(second.payload[:psp_reference]).to eq("pi_#{checkout.reference}")
      expect(captures).to eq([checkout.reference]) # NOT charged a second time
      expect(settlement_count).to eq(1) # NO second settlement minted
    end

    # The operator's work after the payment reads the settlement, so the
    # provider hears of it only once the row exists, and once.
    it 'tells the provider the checkout is settled after the settlement row is written, and not on the replay' do
      seen = []
      allow(provider).to receive(:settled) { |settled_checkout| seen << [settled_checkout.reference, settlement_count] }

      2.times { pay }

      expect(seen).to eq([[checkout.reference, 1]])
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

  describe 'a repeated pay of an unfinished pair' do
    include_context 'with a replayed pay against real Postgres'

    # The trail is persisted and nothing was captured: the call stopped before
    # the capture. The repeat captures and settles.
    it 'captures and settles a pair that was persisted but never captured' do
      persist_trail

      expect(pay.payload).to include(psp_reference: "pi_#{checkout.reference}", settled_amount_cents: 1599)
      expect(captures).to eq([checkout.reference])
      expect(settlement_count).to eq(1)
    end

    # The capture returned and phase 3 never committed. The repeat charges again
    # under the same reference, which the PSP answers with the first charge, and
    # writes the missing settlement.
    it 'settles a pair whose capture ran but whose settlement was never written' do
      allow(described_class).to receive(:new).and_return(executor)
      allow(executor).to receive(:persist_settlement)
        .and_raise(StandardError, 'connection reset during settlement insert')
      expect { pay }.to raise_error(StandardError, /connection reset/)
      expect(settlement_count).to eq(0)

      allow(executor).to receive(:persist_settlement).and_call_original
      expect(pay.payload[:psp_reference]).to eq("pi_#{checkout.reference}")
      expect(captures).to eq([checkout.reference, checkout.reference])
      expect(settlement_count).to eq(1)
      expect(pay.payload[:psp_reference]).to eq("pi_#{checkout.reference}")
      expect(captures).to eq([checkout.reference, checkout.reference])
    end
  end

  describe 'a repeated pay of an unfinished pair, concurrent or declined' do
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

    it 'answers 409 conflict to a repeat of a declined pair, before any capture' do
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

  # One checkout settles at most once: a second live pair for it is refused,
  # and a pair after a declined one is a new attempt.
  describe 'a second pair for one checkout' do
    include_context 'with a replayed pay against real Postgres'

    let(:second) { another_checkout('2', checkout_hash: checkout.checkout_hash) }
    let(:second_payment) { payment_for(second, '2') }

    def pay_second
      allow(Kiosk::Server::MandateVerifier).to receive_messages(verify_checkout: second, verify_payment: second_payment)
      described_class.call(kind: :pay, args: pay_args(second, second_payment), identity: identity, connection: connection)
    end

    it 'answers 409 to a second pair while the first is unresolved, before any capture' do
      allow(provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('unknown', retryable: false))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)

      expect { pay_second }.to raise_error(Kiosk::Server::Errors::Conflict)
      expect(provider).to have_received(:capture).once
    end

    it 'answers 409 to a second pair for a settled checkout' do
      pay

      expect { pay_second }.to raise_error(Kiosk::Server::Errors::Conflict)
      expect(captures).to eq([checkout.reference])
    end

    it 'settles a second pair after the first was declined' do
      allow(provider).to receive(:capture).and_raise(Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)
      allow(provider).to receive(:capture) { |charged, **| { psp_reference: "pi_#{charged.reference}", settled_amount_cents: 1599 } }

      expect(pay_second.payload[:psp_reference]).to eq("pi_#{second.reference}")
      expect(settlement_count).to eq(1)
    end
  end

  describe 'a repeated pay after an unknown outcome' do
    include_context 'with a replayed pay against real Postgres'

    it 'keeps an unknown outcome open: the repeat charges again under the same key' do
      allow(provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('unknown', retryable: false))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e| expect(e.hint).to include('SAME two mandates') }

      expect(pay.payload[:psp_reference]).to eq("pi_#{checkout.reference}")
      expect(settlement_count).to eq(1)
    end
  end

  describe 'a replayed pay that is not the same request' do
    include_context 'with a replayed pay against real Postgres'

    # A REFERENCE RE-USED WITH DIFFERENT CONTENT IS NOT A REPLAY. The
    # settlement this principal already has must NOT be handed to it as the
    # answer to a different request. The `sd_jwt` equality in the lookup says so.
    it 'refuses to hand the settlement to a pair whose bytes differ (same reference, new content)' do
      pay
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_checkout).and_return(checkout.with(sd_jwt: 'checkout-sd-jwt-TAMPERED'))

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
      expect(captures).to eq([checkout.reference])
      expect(settlement_count).to eq(1)
    end

    # And the lookup is scoped to the acting principal on every mandate row:
    # another assistant's user_id sees no settlement of this one's.
    it "does not answer a DIFFERENT principal with this principal's settlement" do
      pay
      stranger = build_identity(user_id: SecureRandom.uuid, agent_id: SecureRandom.uuid)
      chain = described_class::Chain.new(checkout, payment)
      expect(described_class.new(connection: connection, identity: stranger).send(:chain_record, chain)).to be_nil
    end
  end
end
