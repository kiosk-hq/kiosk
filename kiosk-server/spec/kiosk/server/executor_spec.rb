# frozen_string_literal: true

module ExecutorSpecHelpers
  # The INSERT column order of the three persist helpers, so a recorded row
  # reads by name instead of by bind index.
  INSERT_COLUMNS = {
    'checkout_mandates' => %w[reference checkout_hash user_id agent_id issuer line_items
                              total_amount_cents currency expires_at sd_jwt],
    'payment_mandates' => %w[reference checkout_mandate_id user_id agent_id issuer payment_instrument
                             amount_cents currency expires_at sd_jwt],
    'settlements' => %w[checkout_mandate_id user_id agent_id issuer psp_reference
                        settled_amount_cents currency]
  }.freeze

  def pay(args = valid_args, as: identity)
    described_class.call(kind: :pay, args: args, identity: as, connection: connection)
  end

  # Registers `handler` as the callable of verb `name`, the shape the engine's own verbs take.
  def register(kind, name, &handler)
    registry = kind == :query ? Kiosk::Server::Queries : Kiosk::Server::Actions
    registry.declare(name, handler, input_schema: { type: 'object' }, output_schema: true)
  end

  def run_boom(kind: :run)
    register(kind == :run ? :action : :query, 'boom') { raise 'kaboom' }
    described_class.call(kind: kind, args: {}, name: 'boom',
                         identity: identity, connection: connection)
  end

  def fail_capture(message, **)
    allow(Kiosk.configuration.payment_provider).to receive(:capture)
      .and_raise(Kiosk::PaymentProviders::PaymentFailed.new(message, **))
  end

  # [sql, name, binds] of the single statement the call under test ran.
  def last_statement = connection.exec_queries.last
end

module ExecutorSpecReplayHelpers
  # {Executor#chain_record}'s meaning, evaluated over the recorded rows: the
  # checkout mandate matched by (user_id, reference, sd_jwt), its payment
  # mandate matched by the FK AND its own sd_jwt, then that checkout's
  # settlement, if any. Drop the sd_jwt comparisons and a pair re-used with
  # different content would be handed a settlement it did not buy.
  def chain_rows(stored, binds)
    user_id, reference, checkout_sd_jwt, payment_sd_jwt = binds

    checkout = stored_row(stored, 'checkout_mandates', 'reference' => reference, 'user_id' => user_id, 'sd_jwt' => checkout_sd_jwt)
    return [] if checkout.nil?
    return [] unless stored_row(stored, 'payment_mandates', 'checkout_mandate_id' => checkout['id'], 'user_id' => user_id,
                                                            'sd_jwt' => payment_sd_jwt)

    [chain_row(checkout, stored['settlements'].find { |r| r['checkout_mandate_id'] == checkout['id'] } || {})]
  end

  def chain_row(checkout, settlement)
    { 'checkout_row' => checkout['id'], 'declined_at' => checkout['declined_at'], 'settlement_id' => settlement['id'],
      'psp_reference' => settlement['psp_reference'], 'settled_amount_cents' => settlement['settled_amount_cents'],
      'currency' => settlement['currency'] }
  end

  def stored_row(stored, table, match)
    stored[table].find { |r| match.all? { |column, value| r[column] == value } }
  end

  def route_mandate_tables
    route_exec_query(connection) { |sql, binds| route_mandate(sql, binds) }
  end

  def route_mandate(sql, binds)
    return record_insert(sql, binds) if sql.include?('INSERT INTO')
    return chain_rows(stored, binds) if sql.include?('LEFT JOIN')
    return record_decline(binds.first) if sql.include?('SET declined_at')

    [{ 'id' => "row-#{inserted.size}" }]
  end

  def record_decline(checkout_row)
    stored['checkout_mandates'].find { |r| r['id'] == checkout_row }['declined_at'] = Time.current
    []
  end

  # The shipped schema's unique keys: `(user_id, reference)` on both mandate
  # tables, one live checkout mandate per checkout, one settlement per checkout mandate.
  def record_insert(sql, binds)
    table = sql[/INSERT INTO \S+\.(\w+)/, 1]
    row   = ExecutorSpecHelpers::INSERT_COLUMNS.fetch(table).zip(binds).to_h
    raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint' if duplicate?(table, row)

    inserted << [table, binds.first]
    id = "row-#{inserted.size}"
    stored[table] << row.merge('id' => id)
    [{ 'id' => id }]
  end

  def duplicate?(table, row)
    return true if inserted.include?([table, row.values.first])

    table == 'checkout_mandates' &&
      stored[table].any? { |r| r['checkout_hash'] == row['checkout_hash'] && r['declined_at'].nil? }
  end

  # A second pair the assistant signed for `checkout_hash`: new references, new bytes.
  def stub_second_pair(checkout_hash: checkout.checkout_hash)
    checkout2 = Kiosk::Mandate::CheckoutMandate.new(**checkout.to_h, reference: 'cm-2', checkout_hash:, sd_jwt: 'checkout-sd-jwt-2')
    payment2  = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, reference: 'pm-2', transaction_id: checkout_hash,
                                                                   sd_jwt: 'payment-sd-jwt-2')
    allow(Kiosk::Server::MandateVerifier).to receive_messages(verify_checkout: checkout2, verify_payment: payment2)
  end
end

RSpec.shared_context 'with a fake executor connection' do
  include ExecutorSpecHelpers

  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: 'agent') }
end

RSpec.shared_context 'with pay mandates' do
  include_context 'with a fake executor connection'

  let(:identity) { build_identity(agent_id: 'a-1') }
  let(:expires_at) { nil }
  let(:checkout) do
    Kiosk::Mandate::CheckoutMandate.new(
      reference: 'cm-1', checkout_hash: 'hash-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', line_items: [{ 'sku' => 'pizza', 'qty' => 1 }],
      total_amount_cents: 1599, currency: 'eur', expires_at: expires_at, sd_jwt: 'checkout-sd-jwt'
    )
  end
  let(:payment) do
    Kiosk::Mandate::PaymentMandate.new(
      reference: 'pm-1', transaction_id: 'hash-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', payment_instrument: 'pm_card_visa',
      amount_cents: 1599, currency: 'eur', expires_at: expires_at, sd_jwt: 'payment-sd-jwt'
    )
  end
end

# `Executor.call` builds one instance per call; this hands the spec the one
# it builds for `identity`, so an example stubs that instance's helpers. A
# call for any other identity builds a fresh instance.
RSpec.shared_context 'with the executor instance a call builds' do
  let(:executor) { described_class.new(connection: connection, identity: identity) }

  before do
    built = executor
    allow(described_class).to receive(:new).and_call_original
    allow(described_class).to receive(:new).with(connection: connection, identity: identity).and_return(built)
  end
end

RSpec.shared_context 'with verb :pay' do
  include_context 'with pay mandates'
  include_context 'with the executor instance a call builds'

  let(:settlement) { { psp_reference: 'pi_1', settled_amount_cents: 1599, settled_at: Time.current } }
  let(:valid_args) { { checkout_mandate: 'checkout-sd-jwt', payment_mandate: 'payment-sd-jwt' } }

  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.issuer = 'https://demo.example' }
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_checkout)
      .with(sd_jwt: 'checkout-sd-jwt', identity: identity).and_return(checkout)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment)
      .with(sd_jwt: 'payment-sd-jwt', identity: identity, checkout: checkout).and_return(payment)
    # Persist helpers return SERVER-generated ids (uuid PKs); the verb
    # threads them through the FK chain.
    { persist_checkout_mandate: 'checkout-row', persist_payment_mandate: 'pay-row', persist_settlement: 's-1',
      lock_assistant_payments!: nil, checkout_recorded?: false }.each do |helper, value|
      allow(executor).to receive(helper).and_return(value)
    end
    Kiosk.configuration.payment_provider = instance_double(Kiosk::PaymentProviders::Base, capture: settlement, setup_required?: false)
  end
end

# ── Replay: the two mandates ARE the idempotency key (K-739) ───────────
#
# `pay` publishes no idempotency header and no idempotency field, and the
# spec (protocol.md §11.6) says why it needs none: the mandates' references
# already are one, and an assistant whose `pay` response was lost retries
# with the IDENTICAL pair. These examples pin BOTH halves of the behaviour
# that claim rests on, at the only layer where "how many times was the card
# charged" is observable without a database.
#
# The persist helpers run FOR REAL here (the enclosing `before` stubs them;
# this context calls them through) against a router that enforces the
# constraints the shipped schema declares. So the 409 is produced by the same
# `unique_violation?` remap a real Postgres would trip, not by a stub.
RSpec.shared_context 'with a pay replayed with the identical mandates' do
  include_context 'with verb :pay'
  include ExecutorSpecReplayHelpers

  # `[table, first bound value]` for every row the router has accepted. One
  # principal per example, so that value alone is the whole key.
  let(:inserted) { [] }
  let(:captures) { [] }
  # The rows those inserts wrote, by table, each as a column=>value hash
  # plus the server id the statement returned. K-850's replay lookup is a
  # READ, so a router that answers it has to have kept what was written.
  let(:stored) { Hash.new { |h, k| h[k] = [] } }

  before do
    stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))

    %i[persist_checkout_mandate persist_payment_mandate persist_settlement].each do |helper|
      allow(executor).to receive(helper).and_call_original
    end

    route_mandate_tables

    Kiosk.configuration.payment_provider = instance_double(Kiosk::PaymentProviders::Base, setup_required?: false)
    %i[capture resume].each do |call|
      allow(Kiosk.configuration.payment_provider).to receive(call) do |checkout, **_kwargs|
        captures << checkout.reference
        settlement
      end
    end
  end
end

# ── The pay path's statements carry BIND PARAMETERS, not spliced values ───
#
# K-654: these INSERTs (and the spending-cap SELECT) used to be heredocs
# with every field run through a private `q()` = `connection.quote`. This
# group asserts the shape that replaced it — `$N` placeholders, values handed
# over separately and in order — and, above all, that `connection.quote` is
# not reachable from the pay path at all.
#
# What this group deliberately does NOT claim is that the values are STORED
# correctly: a fake connection cannot know what Postgres makes of a bind's
# type. That is `executor_persistence_spec.rb`, against a real database.
RSpec.shared_context 'with pay-path persistence (bind parameters)' do
  subject(:executor) { described_class.new(connection: connection, identity: identity) }

  include_context 'with pay mandates'

  let(:expires_at) { Time.at(1_800_000_071).utc }

  before { Kiosk.configure { |c| c.schema = 'kiosk' } }
end

# The real verifier over really signed mandates, so the answer is read end to end.
RSpec.shared_context 'with really signed mandates' do
  include_context 'with a checkout to pay'
  include_context 'with the executor instance a call builds'

  let(:connection) { FakeConnection.new }

  before do
    allow(Kiosk::Server::SessionContext).to receive(:open) { |**_kw, &blk| blk.call }
    { persist_checkout_mandate: 'checkout-row', persist_payment_mandate: 'pay-row', persist_settlement: 's-1' }.each do |helper, value|
      allow(executor).to receive(helper).and_return(value)
    end
    Kiosk.configuration.payment_provider = instance_double(
      Kiosk::PaymentProviders::Base,
      capture: { psp_reference: 'pi_1', settled_amount_cents: 450, settled_at: Time.current },
      setup_required?: false
    )
  end

  def answered(currency)
    checkout_jwt = checkout(currency:)
    pair = Kiosk::TestHelpers::Mandate.pay(agent_key, checkout_jwt)
    described_class.call(kind: :pay, args: { checkout_mandate: pair[:checkout], payment_mandate: pair[:payment] },
                         identity: identity, connection: connection).payload[:currency]
  end
end

RSpec.describe Kiosk::Server::Executor do
  describe '.call construction' do
    include_context 'with a fake executor connection'

    it 'raises Unauthenticated when identity is nil' do
      expect do
        described_class.call(kind: :run, args: {}, name: 'ping', identity: nil, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::Unauthenticated, /identity/)
    end

    it 'raises BadRequest for an unknown verb' do
      expect do
        described_class.call(kind: :wat, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest) { |e|
        expect(e.hint).to include('query')
      }
    end
  end

  describe 'transaction discipline' do
    include_context 'with a fake executor connection'

    it 'wraps the verb in a single transaction with GUCs set' do
      register(:query, 'probe') { [{ ok: 1 }] }
      described_class.call(kind: :query, args: {}, name: 'probe', identity: identity, connection: connection)

      # 4 GUC statements only (the handler answers rows without hitting
      # connection). They are `set_config` binds since K-789, so the GUC name
      # is the first bind rather than part of the statement text.
      gucs = connection.bound(/set_config/)
      expect(gucs.size).to eq(4)
      expect(gucs.first.last.first).to eq('app.current_user_id')
      expect(gucs.last.last.first).to eq('app.current_agent_id')
      expect(connection.executed_sql).to be_empty
      expect(connection.in_transaction?).to be(false) # closed after call
    end
  end

  describe 'verb :query' do
    include_context 'with a fake executor connection'

    before do
      register(:query, 'menu') { [{ 'id' => 1, 'name' => 'Margherita' }] }
    end

    it 'looks up the query by name and returns :rows Result' do
      result = described_class.call(
        kind: :query, args: {}, name: 'menu',
        identity: identity, connection: connection
      )

      expect(result).to be_a(Kiosk::Server::Result)
      expect(result.kind).to    eq(:rows)
      expect(result.payload).to eq([{ 'id' => 1, 'name' => 'Margherita' }])
    end

    it 'passes params (args minus name) to the query handler' do
      register(:query, 'items') { |args| [{ 'filter' => args[:category] }] }
      result = described_class.call(
        kind: :query, args: { category: 'pizza' }, name: 'items',
        identity: identity, connection: connection
      )
      expect(result.payload).to eq([{ 'filter' => 'pizza' }])
    end
  end

  describe 'verb :query refusals' do
    include_context 'with a fake executor connection'

    it 'raises BadRequest when name is missing' do
      expect do
        described_class.call(kind: :query, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest, /name/)
    end

    it "raises VerbNotFound when the query isn't registered" do
      expect do
        described_class.call(kind: :query, args: {}, name: 'missing',
                             identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::VerbNotFound)
    end

    it 'lets Kiosk::Server::Errors raised inside the query propagate unchanged' do
      register(:query, 'denied') { raise Kiosk::Server::Errors::RLSDenied, 'no' }

      expect do
        described_class.call(kind: :query, args: {}, name: 'denied',
                             identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end
  end

  describe 'verb :query handler crash' do
    include_context 'with a fake executor connection'

    # THE WIRE GETS THE CLASS, THE OPERATOR GETS THE SENTENCE (K-1307).
    #
    # This example matched `/kaboom/` — the handler's OWN words, spliced into
    # the refusal — so it asserted that an arbitrary Ruby message reaches the
    # caller, which is the thing K-465, K-1294 and K-1307 each closed one batch
    # of. It now asserts the opposite in both directions: the sentence names
    # the exception CLASS (deliberately kept: a class name carries none of the
    # caller's bytes and does not move when a dependency is upgraded), carries
    # no syllable of the message, and the message is on the operator's log
    # where the `hint` has always promised the backtrace would be.
    it 'wraps StandardError raised inside the query as ActionFailed' do
      register(:query, 'boom') { raise 'kaboom' }

      expect do
        expect do
          described_class.call(kind: :query, args: {}, name: 'boom',
                               identity: identity, connection: connection)
        end.to raise_error(Kiosk::Server::Errors::ActionFailed) { |e|
          expect(e.message).to eq('Query "boom" failed')
          expect(e.message).not_to include('kaboom')
          expect(e.hint).to eq('See server logs for the backtrace.')
        }
      end.to output(/\[kiosk-server\] Query "boom" raised RuntimeError: kaboom/).to_stderr
    end
  end

  # ── cursor pagination seam (ADR-0021 / T-042) ─────────────────────────
  describe 'verb :query pagination' do
    include_context 'with a fake executor connection'

    it 'leaves next_cursor nil when the handler returns a bare Array (back-compat)' do
      register(:query, 'flat') { [{ 'id' => 1 }, { 'id' => 2 }] }
      result = described_class.call(kind: :query, args: {}, name: 'flat',
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ 'id' => 1 }, { 'id' => 2 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_payload).to be_an(Array) # a bare array, like every query
    end

    it 'omits `next` when a paginating handler signals the last page (Page with nil cursor)' do
      register(:query, 'last') { Kiosk::Server::Page.new(rows: [{ 'id' => 99 }]) } # no next_cursor => complete
      result = described_class.call(kind: :query, args: {}, name: 'last',
                                    identity: identity, connection: connection)

      expect(result.payload).to     eq([{ 'id' => 99 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_payload).to be_an(Array) # a bare array, like every query
    end
  end

  describe 'verb :query next page' do
    include_context 'with a fake executor connection'

    # T-092: the cursor reaches the RESULT, never the body. The wire turns it
    # into `Link: …; rel="next"`; the Executor's job ends at carrying it.
    it "threads a Page's next_cursor and total onto the Result, not into the body" do
      register(:query, 'paged') do |args|
        offset = Kiosk::Server::Cursor.decode_offset(args[:cursor])
        Kiosk::Server::Page.new(rows: [{ 'id' => offset + 1 }],
                                next_cursor: Kiosk::Server::Cursor.encode_offset(offset + 1), total: 42)
      end

      result = described_class.call(kind: :query, args: { limit: 1 }, name: 'paged',
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ 'id' => 1 }])
      expect(result.next_cursor).to eq(Kiosk::Server::Cursor.encode_offset(1))
      expect(result.total).to       eq(42)
      expect(result.to_payload).to  eq([{ 'id' => 1 }])
    end
  end

  describe 'verb :run' do
    include_context 'with a fake executor connection'

    before do
      register(:action, 'ping') { |args| { 'pong' => args[:greeting] } }
    end

    it 'looks up the action by name and calls it with sym-keyed args' do
      result = described_class.call(
        kind: :run, args: { greeting: 'world' }, name: 'ping',
        identity: identity, connection: connection
      )

      expect(result.kind).to    eq(:value)
      expect(result.payload).to eq('pong' => 'world')
    end

    it 'passes through args (except name) to the action handler' do
      register(:action, 'echo') { |args| { 'a' => args[:a], 'b' => args[:b] } }
      result = described_class.call(
        kind: :run, args: { a: 1, b: 'x' }, name: 'echo',
        identity: identity, connection: connection
      )
      expect(result.payload).to eq('a' => 1, 'b' => 'x')
    end

    it 'calls the handler it is given in place of the registered one' do
      result = described_class.new(connection: connection, identity: identity).call(
        kind: :run, args: { greeting: 'there' }, name: 'ping', handler: ->(args) { { 'in_place' => args[:greeting] } }
      )
      expect(result.payload).to eq('in_place' => 'there')
    end
  end

  describe 'verb :run refusals' do
    include_context 'with a fake executor connection'

    it 'raises BadRequest when name is missing' do
      expect do
        described_class.call(kind: :run, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest, /name/)
    end

    it "raises VerbNotFound when the action isn't registered" do
      expect do
        described_class.call(kind: :run, args: {}, name: 'missing',
                             identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::VerbNotFound)
    end

    it 'lets Kiosk::Server::Errors raised inside the action propagate unchanged' do
      register(:action, 'denied') { raise Kiosk::Server::Errors::RLSDenied, 'no' }

      expect do
        described_class.call(kind: :run, args: {}, name: 'denied',
                             identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end
  end

  describe 'verb :run handler crash' do
    include_context 'with a fake executor connection'

    # Same split as the query branch above, and it is asserted twice because
    # the two rescues are two pieces of code: a fix applied to one of them and
    # not the other is exactly the half-done shape this class keeps recurring
    # as.
    it 'wraps StandardError raised inside the action as ActionFailed' do
      register(:action, 'boom') { raise 'kaboom' }

      expect do
        expect do
          described_class.call(kind: :run, args: {}, name: 'boom',
                               identity: identity, connection: connection)
        end.to raise_error(Kiosk::Server::Errors::ActionFailed) { |e|
          expect(e.message).to eq('Action "boom" failed')
          expect(e.message).not_to include('kaboom')
          expect(e.message).not_to include('RuntimeError')
          expect(e.hint).to eq('See server logs for the backtrace.')
        }
      end.to output(/\[kiosk-server\] Action "boom" raised RuntimeError: kaboom/).to_stderr
    end
  end

  # ── THE OPERATOR'S ONLY DIAGNOSTIC FOR A CRASH IN THEIR OWN HANDLER ──────
  #
  # Since K-1307 the wire error names the exception CLASS and stops. That makes
  # this report the ONE place the message and the backtrace survive, and it is
  # not a nice-to-have: both 500 paths raise `hint: "See server logs for the
  # backtrace."`, so an operator who finds nothing in the log has been sent to
  # a place the server promised to write to and did not. The audit event is no
  # substitute — it is built from the wire error, not from the cause — and
  # neither is the exception's own `#cause`, which nothing on the wire renders.
  #
  # The four properties below are the ones that make it a diagnostic rather
  # than a line of output: WHAT it says, WHERE it goes when the host app has a
  # logger, that it is BOUNDED, and that it can never turn one failure into
  # two. The last is the reason `report_handler_failure` ends in a bare rescue,
  # and a bare rescue is exactly the kind of code that is never exercised until
  # it matters — {AuditSink}'s sibling guarantee is asserted the same way, one
  # file over.
  describe "reporting a handler's crash to the operator" do
    include_context 'with a fake executor connection'

    let(:logger) { instance_double(Logger, error: nil) }

    it 'warns the verb, the class, the MESSAGE and the backtrace when the host has no logger' do
      # Rails is loaded in this suite (ActionController::Base is), and
      # `Rails.logger` is nil until an application boots — which is also a rake
      # task, a console and an operator's own script. `Kernel#warn` is the
      # fallback, the same one AuditSink#report takes.
      expect(Rails.logger).to be_nil

      expect { expect { run_boom }.to raise_error(Kiosk::Server::Errors::ActionFailed) }
        .to output(/\[kiosk-server\] Action "boom" raised RuntimeError: kaboom\n  .*executor_spec\.rb/)
        .to_stderr
    end

    it "reports a QUERY's crash too — both 500 paths, not just the audited one" do
      expect { expect { run_boom(kind: :query) }.to raise_error(Kiosk::Server::Errors::ActionFailed) }
        .to output(/\[kiosk-server\] Query "boom" raised RuntimeError: kaboom/).to_stderr
    end

    it 'sends it to Rails.logger.error, and NOT to stderr, once an app has booted' do
      allow(Rails).to receive(:logger).and_return(logger)

      expect { expect { run_boom }.to raise_error(Kiosk::Server::Errors::ActionFailed) }
        .not_to output.to_stderr

      expect(logger).to have_received(:error) { |message|
        expect(message).to include('Action "boom" raised RuntimeError: kaboom')
        expect(message).to include('executor_spec.rb')
      }
    end
  end

  describe "reporting a handler's crash safely" do
    include_context 'with a fake executor connection'
    include_context 'with the executor instance a call builds'

    let(:logger) { instance_double(Logger, error: nil) }

    it 'BOUNDS the backtrace — a report is a pointer, not the whole stack' do
      allow(Rails).to receive(:logger).and_return(logger)
      register(:action, 'deep') do
        recurse = ->(n) { n.zero? ? raise('kaboom') : recurse.call(n - 1) }
        recurse.call(60)
      end

      expect do
        described_class.call(kind: :run, args: {}, name: 'deep',
                             identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::ActionFailed)

      expect(logger).to have_received(:error) { |message|
        # One headline line plus at most the 20 frames the reporter keeps —
        # the raise above supplies more than 60, so an unbounded report would
        # be caught here rather than in someone's log rotation.
        expect(message.lines.size).to eq(21)
      }
    end

    it 'does not turn one failure into two when the LOGGER is the thing that raises' do
      allow(Rails).to receive(:logger).and_return(logger)
      allow(logger).to receive(:error).and_raise(IOError, 'the log volume is gone')

      # The ACTION's failure reaches the caller unchanged; the logger's does
      # not reach it at all.
      expect { run_boom }.to raise_error(Kiosk::Server::Errors::ActionFailed) { |e|
        expect(e.message).to eq('Action "boom" failed')
      }
    end

    it 'does not turn one failure into two when STDERR is the thing that raises' do
      allow(executor).to receive(:warn).and_raise(IOError, 'stderr is gone')

      expect { run_boom }.to raise_error(Kiosk::Server::Errors::ActionFailed)
    end
  end

  # The `events` verb was removed (never a capability). It is
  # now an unknown verb → a clean 400 BadRequest, not a raw NotImplementedError.
  describe 'removed :events verb' do
    include_context 'with a fake executor connection'

    it 'is rejected as an unknown verb (clean BadRequest, not NotImplementedError)' do
      expect do
        described_class.call(kind: :events, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb/)
    end
  end

  # ── `:schema` LEFT THIS DISPATCHER (T-094) ────────────────────────────
  #
  # `GET <endpoint>/schema` is PUBLIC now: it resolves no identity, and an
  # Executor cannot be built without one. The catalog it used to render lives
  # in {Kiosk::Server::SchemaDocument}, derived at boot and specced next door
  # in schema_document_spec.rb. What stays here is the pair of facts that keep
  # the two vocabularies honest.
  describe 'verb :schema (no longer dispatchable)' do
    include_context 'with a fake executor connection'

    it 'is refused as an unknown verb, with the valid three named' do
      expect do
        described_class.call(kind: :schema, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb: :schema/)
    end

    # And it is no longer a POLICY verb either. `POLICY_VERBS` existed for one
    # caller — `/kiosk/openapi.json`, tolled as `:schema` while it was still
    # Bearer-gated. K-804 made that endpoint public, nothing tolls as
    # `:schema`, and a constant that was a byte-identical copy of {VERBS}
    # under another name was deleted rather than left as documentation.
    it 'is gone from the vocabulary entirely — one list, not two' do
      expect(described_class::VERBS).to eq(%i[query run pay])
      expect(described_class.const_defined?(:POLICY_VERBS)).to be(false)
    end
  end

  describe 'verb :help (removed)' do
    include_context 'with a fake executor connection'

    it 'is no longer a recognised verb' do
      expect do
        described_class.call(kind: :help, args: {}, identity: identity, connection: connection)
      end.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb/)
    end
  end

  describe 'verb :pay' do
    include_context 'with verb :pay'

    it 'verifies the mandates, captures, and returns the full settlement payload' do
      result = pay
      expect(result.kind).to eq(:value)
      expect(result.payload).to include(
        settlement_id: 's-1',
        psp_reference: 'pi_1',
        settled_amount_cents: 1599,
        currency: 'eur'
      )
    end

    it 'threads the SERVER-generated checkout id into the payment mandate persist (FK chain)' do
      pay
      expect(executor).to have_received(:persist_payment_mandate).with(checkout_row_id: 'checkout-row', payment: payment)
    end

    it 'threads the SERVER-generated checkout id into the settlement persist (FK chain)' do
      pay
      expect(executor).to have_received(:persist_settlement)
        .with(checkout_row_id: 'checkout-row', checkout: checkout, settled: settlement)
    end

    it 'passes the assistant-presented payment instrument to capture' do
      pay
      expect(Kiosk.configuration.payment_provider).to have_received(:capture)
        .with(checkout, payment_method: 'pm_card_visa')
    end
  end

  describe 'verb :pay per-assistant spending cap' do
    include_context 'with verb :pay'

    it 'does not enforce when no spending_cap seam is configured (default)' do
      allow(executor).to receive(:spent_in_window)
      pay
      expect(executor).not_to have_received(:spent_in_window)
      expect(Kiosk.configuration.payment_provider).to have_received(:capture)
    end

    it 'does not enforce for an assistant the seam reports uncapped (nil)' do
      Kiosk.configuration.spending_cap = ->(**) {}
      allow(executor).to receive(:spent_in_window)
      pay
      expect(executor).not_to have_received(:spent_in_window)
      expect(Kiosk.configuration.payment_provider).to have_received(:capture)
    end

    it 'proceeds when spent + checkout total is within the cap' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      allow(executor).to receive(:spent_in_window).and_return(1000) # +1599 = 2599 <= 5000
      result = pay
      expect(result.kind).to eq(:value)
      expect(Kiosk.configuration.payment_provider).to have_received(:capture)
    end

    it 'rejects with SpendingCapExceeded (403) and does NOT capture when the cap would be exceeded' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 2000, currency: 'eur' } }
      allow(executor).to receive(:spent_in_window).and_return(1000) # +1599 = 2599 > 2000
      expect { pay }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e| expect(e.http_status).to eq(403) }
      expect(Kiosk.configuration.payment_provider).not_to have_received(:capture)
    end
  end

  describe 'verb :pay spending cap tally' do
    include_context 'with verb :pay'

    it 'treats a cap of 0 as disabled (any charge rejected)' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 0, currency: 'eur' } }
      allow(executor).to receive(:spent_in_window).and_return(0)
      expect { pay }
        .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded)
      expect(Kiosk.configuration.payment_provider).not_to have_received(:capture)
    end

    it 'binds the acting agent_id, the checkout currency and the window to the one tally statement' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      Kiosk.configuration.spending_cap_window_days = 7
      tally = nil
      route_exec_query(connection) do |sql, binds|
        tally = binds if sql.include?('AS total')
        [{ 'total' => 0 }]
      end
      pay
      expect(tally).to eq(['a-1', 'eur', 7])
    end

    # K-551: the tally must be scoped to the checkout's currency — summing
    # cents across currencies is meaningless (4999 USD is not within a 5000
    # EUR cap), and a cross-currency sum could erode the cap.
    it "scopes the settled-total tally to the checkout's currency (not currency-blind)" do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'eur' } }
      allow(executor).to receive(:spent_in_window).and_return(0)
      pay
      expect(executor).to have_received(:spent_in_window).with(having_attributes(currency: 'eur'), nil)
    end
  end

  describe "verb :pay spending cap's currency" do
    include_context 'with verb :pay'

    it "refuses a checkout in a currency other than the cap's, before capture" do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'usd' } }
      allow(executor).to receive(:spent_in_window)
      expect { pay }.to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e|
        expect(e.hint).to eq('the cap is in USD; this charge is in EUR')
      }
      expect(executor).not_to have_received(:spent_in_window)
      expect(Kiosk.configuration.payment_provider).not_to have_received(:capture)
    end

    it 'reads the cap currency case-insensitively' do
      Kiosk.configuration.spending_cap = ->(**) { { amount_cents: 5000, currency: 'EUR' } }
      allow(executor).to receive(:spent_in_window).and_return(0)
      pay
      expect(Kiosk.configuration.payment_provider).to have_received(:capture)
    end
  end

  describe 'verb :pay phase-1 errors' do
    include_context 'with verb :pay'

    # N2: a unique-violation surfacing from phase-1 persistence (the same
    # signed mandates replayed) is a 409 Conflict, not a 500. Matched by class
    # NAME so the gem needn't load ActiveRecord in its own unit env.
    it 'maps a phase-1 unique violation to Errors::Conflict (409)' do
      stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))
      allow(executor).to receive(:persist_checkout_mandate)
        .and_raise(ActiveRecord::RecordNotUnique.new('dup key'))
      # K-850: the violation alone does not decide the answer — the executor
      # asks whether THIS pair already settled. Here nothing did (the insert
      # never ran), so the lookup finds no row and the 409 reaches the caller.
      connection.next_exec_result = []

      expect { pay }
        .to raise_error(Kiosk::Server::Errors::Conflict) { |e| expect(e.http_status).to eq(409) }
    end

    it 'lets a non-unique phase-1 error propagate unchanged (not remapped to Conflict)' do
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment)
        .and_raise(Kiosk::Server::Errors::Forbidden.new('payment amount/currency does not match the checkout'))

      expect { pay }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /does not match the checkout/)
    end

    # An agentless principal (user_idp web/mobile session, agent_id nil)
    # cannot pay — mandates are agent-signed. Reject with a clean
    # 403, not a 500 from agent_payment_key(nil) deep in mandate verification.
    it 'rejects an agentless caller (agent_id nil) with a clean 403 before verifying mandates' do
      agentless = build_identity(actor: 'human', agent_id: nil)

      expect { pay(as: agentless) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /agent identity/) { |e| expect(e.http_status).to eq(403) }
      expect(Kiosk::Server::MandateVerifier).not_to have_received(:verify_checkout)
    end
  end

  describe 'verb :pay capture placement' do
    include_context 'with verb :pay'

    it 'does not capture when phase-1 persistence raises a unique violation' do
      stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))
      allow(executor).to receive(:persist_checkout_mandate)
        .and_raise(ActiveRecord::RecordNotUnique.new('dup key'))
      connection.next_exec_result = [] # no settlement for this pair (K-850)
      expect { pay }
        .to raise_error(Kiosk::Server::Errors::Conflict)
      expect(Kiosk.configuration.payment_provider).not_to have_received(:capture)
    end

    # C2: an irreversible PSP capture must never run inside a DB transaction —
    # a ROLLBACK cannot undo a Stripe charge. FakeConnection tracks tx depth.
    it 'captures OUTSIDE any DB transaction' do
      in_tx_at_capture = nil
      Kiosk.configuration.payment_provider = instance_double(Kiosk::PaymentProviders::Base)
      allow(Kiosk.configuration.payment_provider).to receive(:setup_required?).and_return(false)
      allow(Kiosk.configuration.payment_provider).to receive(:capture) do |_checkout, **_kwargs|
        in_tx_at_capture = connection.in_transaction?
        settlement
      end

      pay
      expect(in_tx_at_capture).to be(false)
    end
  end

  describe 'verb :pay payment setup' do
    include_context 'with verb :pay'

    # I-1: provider.setup_required? == true → clean 402 BEFORE Phase 1 persists
    # anything, so the checkout is not held and the agent retries after the
    # human completes the SetupIntent flow.
    it 'raises PaymentSetupRequired (402) before persisting mandates when provider.setup_required? is true' do
      provider = instance_double(Kiosk::PaymentProviders::Base, setup_required?: true)
      Kiosk.configuration.payment_provider = provider

      expect do
        pay
      end.to raise_error(Kiosk::Server::Errors::PaymentSetupRequired) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq('payment_setup_required')
      }
      expect(Kiosk::Server::MandateVerifier).not_to have_received(:verify_checkout)
    end

    # I-1 belt-and-suspenders: if a card is detached between the pre-check and
    # capture (race), the PSP raises SetupRequired and we re-raise it cleanly.
    it 're-raises a capture-time SetupRequired as PaymentSetupRequired (402)' do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::SetupRequired)

      expect do
        pay
      end.to raise_error(Kiosk::Server::Errors::PaymentSetupRequired) { |e|
        expect(e.http_status).to eq(402)
      }
    end
  end

  describe 'verb :pay capture failure' do
    include_context 'with verb :pay'

    # K-545: a card DECLINE (retryable PaymentFailed) becomes a typed
    # `payment_failed` 402, NOT a raw 500. The message is the adapter's
    # human-safe string (no PSP internals) and the hint says no money moved.
    it 'maps a retryable capture-time PaymentFailed to Errors::PaymentFailed (402, payment_failed)' do
      fail_capture('the payment method was declined', retryable: true)

      expect do
        pay
      end.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq('payment_failed')
        expect(e.message).to     eq('the payment method was declined')
        expect(e.hint).to        match(/no money moved|update the payment method/i)
      }
    end

    # An UNKNOWN outcome (timeout / connectivity — non-retryable PaymentFailed)
    # is also a typed 402; its hint sends the SAME mandates again, which the
    # operator charges at most once.
    it 'maps a non-retryable capture-time PaymentFailed to a 402 whose hint sends the same mandates again' do
      fail_capture('the payment processor could not confirm the charge; its status is unknown',
                   retryable: false)

      expect do
        pay
      end.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq('payment_failed')
        expect(e.hint).to        include('Send the SAME two mandates again')
        expect(e.hint).to        include('Do not sign new mandates')
      }
    end
  end

  describe 'verb :pay missing mandates' do
    include_context 'with verb :pay'

    it 'raises BadRequest when checkout_mandate is missing' do
      expect { pay({ payment_mandate: 'payment-sd-jwt' }) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /checkout_mandate/)
    end

    it 'raises BadRequest when payment_mandate is missing' do
      expect { pay({ checkout_mandate: 'checkout-sd-jwt' }) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /payment_mandate/)
    end
  end

  describe 'verb :pay without a payment provider' do
    include_context 'with verb :pay'

    # T-158: `module_not_served` (501), not `forbidden` (403). "This origin does
    # not do payments" is a fact about the ORIGIN and is true of every caller.
    it 'raises ModuleNotServed when no payment_provider is configured' do
      Kiosk.configuration.payment_provider = nil
      expect { pay }
        .to raise_error(Kiosk::Server::Errors::ModuleNotServed, /payment module/)
    end

    it 'puts module_not_served/501 on the wire for it, not a 403' do
      Kiosk.configuration.payment_provider = nil
      expect { pay }
        .to raise_error(Kiosk::Server::Errors::ModuleNotServed) { |e|
          expect(e.code).to        eq('module_not_served')
          expect(e.http_status).to eq(501)
          expect(e.to_problem[:type]).to eq('https://kiosk.tech/problems/module_not_served')
          # `detail` NAMES the module — the only thing separating "no payments
          # here" from "no KYC here" to a reader of the answer.
          expect(e.to_problem[:detail]).to include('payment')
        }
    end

    # K-800: THE ORIGIN ANSWERS BEFORE THE ARGUMENTS DO. An empty POST at a
    # payment-free origin answers `module_not_served`, never an instruction to
    # sign mandates an origin could never settle.
    it 'answers a payment-free origin with module_not_served even when NO mandates are sent (K-800)' do
      Kiosk.configuration.payment_provider = nil
      expect { pay({}) }
        .to raise_error(Kiosk::Server::Errors::ModuleNotServed, /does not serve the payment module/)
    end
  end

  describe 'verb :pay replayed with the identical mandates' do
    include_context 'with a pay replayed with the identical mandates'

    # THE ONE-CHARGE ASSERTION, and since K-850 also the IDEMPOTENCE one.
    # Same args, twice: the second call re-presents `cm-1`, the row is already
    # there, and the unique violation lands in phase 1 — BEFORE phase 2 — where
    # the executor asks whether THIS pair already settled. It did, so the
    # replay is answered with the settlement the first call returned.
    it 'charges once and replays the ORIGINAL settlement the second time (K-850)' do
      first = pay
      expect(first.payload).to include(settlement_id: 'row-3')

      second = pay

      expect(second.kind).to eq(:value)
      expect(second.payload).to eq(first.payload)
      expect(captures).to eq(['cm-1'])
      expect(inserted.count { |table, _| table == 'settlements' }).to eq(1)
    end

    it 'does not answer a settled replay with an error at all (K-850)' do
      pay

      expect { pay }.not_to raise_error
    end

    # A second pair the assistant signs for a checkout already settled holds
    # the checkout's live slot, so it answers 409 before any capture.
    it 'refuses a second pair for a settled checkout, before any capture' do
      pay
      stub_second_pair

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
      expect(captures).to eq(['cm-1'])
    end

    # A second pair for ANOTHER checkout is another purchase: nothing in the
    # engine can tell it from a genuine one, which is why "retry the identical
    # pair, never a new one" lives in the spec and the skill.
    it 'charges again for a pair that pays another checkout' do
      pay
      stub_second_pair(checkout_hash: 'hash-2')

      pay

      expect(captures).to eq(%w[cm-1 cm-2])
    end
  end

  describe 'verb :pay replay boundary' do
    include_context 'with a pay replayed with the identical mandates'

    before do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true))
    end

    # A pair whose charge was declined is closed: no money moved under it, and
    # a repeat answers `409 conflict` before any capture.
    it 'answers 409 conflict to a repeat of a declined pair' do
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
        expect(e.http_status).to eq(409)
        expect(e.code).to        eq('conflict')
      }
      expect(inserted.count { |table, _| table == 'settlements' }).to eq(0)
    end

    # The decline frees the checkout: a new pair for it is a new attempt.
    it 'settles a new pair for the same checkout after a declined charge' do
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)
      allow(Kiosk.configuration.payment_provider).to receive(:capture) do |checkout, **_kwargs|
        captures << checkout.reference
        settlement
      end
      stub_second_pair

      expect(pay.payload).to include(psp_reference: 'pi_1')
      expect(captures).to eq(['cm-2'])
    end

    # A second live pair for one checkout while the first is still unresolved
    # would be a second charge, so it is refused before any capture.
    it 'answers 409 to a second live pair for one checkout, before any capture' do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('unknown', retryable: false))
      expect { pay }.to raise_error(Kiosk::Server::Errors::PaymentFailed)
      stub_second_pair

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict)
      expect(Kiosk.configuration.payment_provider).to have_received(:capture).once
    end

    # A settled checkout mandate re-presented with DIFFERENT signed bytes is
    # not this request, so it is not handed this request's settlement.
    it 'refuses a settled reference re-presented with different bytes (K-850)' do
      allow(Kiosk.configuration.payment_provider).to receive(:capture) do |checkout, **_kwargs|
        captures << checkout.reference
        settlement
      end
      pay
      tampered = Kiosk::Mandate::CheckoutMandate.new(**checkout.to_h, sd_jwt: 'checkout-sd-jwt-TAMPERED')
      allow(Kiosk::Server::MandateVerifier).to receive_messages(verify_checkout: tampered, verify_payment: payment)

      expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
      expect(captures).to eq(['cm-1'])
    end
  end

  describe 'verb :pay phase-3 window' do
    include_context 'with a pay replayed with the identical mandates'

    # The capture succeeds and phase 3 — the transaction that records it —
    # fails. The identical pair sent again charges under the same reference,
    # which the PSP's idempotency key turns into the first charge's answer,
    # and writes the missing settlement.
    it 'resumes a pair whose capture ran but whose settlement was never written' do
      allow(executor).to receive(:persist_settlement)
        .and_raise(StandardError, 'connection reset during settlement insert')
      expect { pay }.to raise_error(StandardError, /connection reset/)
      expect(inserted.map(&:first)).not_to include('settlements')

      allow(executor).to receive(:persist_settlement).and_call_original
      result = pay

      expect(result.payload).to include(psp_reference: 'pi_1', settled_amount_cents: 1599)
      expect(captures).to eq(%w[cm-1 cm-1])
      expect(Kiosk.configuration.payment_provider).to have_received(:resume).once
      expect(inserted.count { |table, _| table == 'settlements' }).to eq(1)
    end
  end

  describe 'pay-path mandate inserts' do
    include_context 'with pay-path persistence (bind parameters)'

    it 'binds every checkout-mandate value, with line_items as JSON text under an explicit ::jsonb cast' do
      id = executor.send(:persist_checkout_mandate, checkout)
      sql, name, binds = last_statement

      expect(id).to   eq('row-1') # the RETURNING id the fake hands back
      expect(name).to eq('Kiosk checkout_mandate insert')
      expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)')
      expect(binds).to eq([
                            'cm-1', 'hash-1', 'u-1', 'a-1', 'https://demo.example',
                            %([{"sku":"pizza","qty":1}]), 1599, 'eur', expires_at, 'checkout-sd-jwt'
                          ])
    end

    it 'binds every payment-mandate value' do
      executor.send(:persist_payment_mandate, checkout_row_id: 'checkout-row', payment: payment)
      sql, name, binds = last_statement

      expect(name).to eq('Kiosk payment_mandate insert')
      expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)')
      expect(binds).to eq([
                            'pm-1', 'checkout-row', 'u-1', 'a-1', 'https://demo.example',
                            'pm_card_visa', 1599, 'eur', expires_at, 'payment-sd-jwt'
                          ])
    end
  end

  describe 'pay-path settlement insert' do
    include_context 'with pay-path persistence (bind parameters)'

    it 'binds every settlement value' do
      executor.send(:persist_settlement, checkout_row_id: 'checkout-row', checkout: checkout,
                                         settled: { psp_reference: 'pi_1', settled_amount_cents: 1599 })
      sql, name, binds = last_statement

      expect(name).to eq('Kiosk settlement insert')
      expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6, $7, now())')
      expect(binds).to eq(['checkout-row', 'u-1', 'a-1', 'https://demo.example', 'pi_1', 1599, 'eur'])
      # Nobody signs a settlement: no `sd_jwt` column, asserted on the column
      # list too, because a statement naming it while binding nothing would
      # satisfy the line above.
      expect(sql).not_to include('sd_jwt')
    end
  end

  describe 'pay-path persistence (bind parameters)' do
    include_context 'with pay-path persistence (bind parameters)'

    # The regression guard the row is actually about: no value — not even a
    # harmless one — may appear in the statement text, and `quote` must never
    # be called. Written over all three helpers so a future statement that
    # forgets is caught by the same assertion.
    it 'never calls connection.quote and never lets a value reach the SQL text' do
      allow(connection).to receive(:quote)

      checkout_row = executor.send(:persist_checkout_mandate, checkout)
      executor.send(:persist_payment_mandate, checkout_row_id: checkout_row, payment: payment)
      executor.send(:persist_settlement, checkout_row_id: checkout_row, checkout: checkout,
                                         settled: { psp_reference: 'pi_1', settled_amount_cents: 1599 })

      expect(connection).not_to have_received(:quote)
      expect(connection.exec_queries.size).to eq(3)
      connection.exec_queries.each do |sql, _name, binds|
        binds.each do |value|
          next if value.is_a?(Integer) # a bare number is not evidence of splicing

          expect(sql).not_to include(value.to_s)
        end
      end
    end
  end

  describe 'pay-path #spent_in_window' do
    include_context 'with pay-path persistence (bind parameters)'

    before { connection.next_exec_result = [{ 'total' => 0 }] }

    def spent(currency, window_days) = executor.send(:spent_in_window, Struct.new(:currency).new(currency), window_days)

    it 'binds the agent and the currency, with no window predicate when uncapped by time' do
      spent('eur', nil)
      sql, name, binds = last_statement

      expect(name).to eq('Kiosk spent total')
      # The predicate folds the COLUMN, for settlement rows written before the
      # mandate boundary canonicalised what fills it.
      expect(sql).to  include('WHERE agent_id = $1 AND lower(btrim(currency)) = $2')
      expect(sql).not_to include('settled_at')
      expect(binds).to eq([identity.agent_id, 'eur'])
    end

    it 'binds the window length rather than interpolating the day count' do
      spent('eur', 7)
      sql, _name, binds = last_statement

      expect(sql).to include('AND settled_at >= now() - make_interval(days => $3)')
      expect(sql).not_to include('7')
      expect(binds).to eq([identity.agent_id, 'eur', 7])
    end

    # The BIND is folded too, so a caller that hands over a checkout the
    # verifier never canonicalised still reads the same tally.
    it 'canonicalises the currency it binds' do
      spent('EUR', nil)
      _sql, _name, binds = last_statement

      expect(binds).to eq([identity.agent_id, 'eur'])
    end
  end

  # The currency `pay` ANSWERS with is the operator's canonical one. The
  # `verb :pay` groups stub `MandateVerifier.verify_*`, so this group runs the
  # REAL verifier on really signed mandates and reads the answer.
  describe 'the currency a `pay` answers with (§11.3, K-1257)' do
    include_context 'with really signed mandates'

    it 'answers `eur` to a checkout in `EUR`' do
      expect(answered('EUR')).to eq('eur')
    end

    # The control: the only case where the answer equals the input bytes.
    it 'answers `eur` to a checkout already in `eur`, which is the only case where the bytes match' do
      expect(answered('eur')).to eq('eur')
    end
  end
end
