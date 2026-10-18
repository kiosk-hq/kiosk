# frozen_string_literal: true

module ExecutorSpecHelpers
  # The INSERT column order of the four persist helpers, so a recorded row
  # reads by name instead of by bind index.
  INSERT_COLUMNS = {
    'intent_mandates' => %w[mandate_id user_id agent_id issuer scope cap_amount_cents
                            currency expires_at raw_jws],
    'cart_mandates' => %w[mandate_id intent_mandate_id user_id agent_id issuer line_items
                          total_amount_cents currency expires_at raw_jws],
    'payment_mandates' => %w[mandate_id cart_mandate_id user_id agent_id issuer payment_method
                             amount_cents currency expires_at raw_jws],
    'settlements' => %w[cart_mandate_id user_id agent_id issuer psp_reference
                        settled_amount_cents currency]
  }.freeze

  def pay(args = valid_args, as: identity)
    described_class.call(kind: :pay, args: args, identity: as, connection: connection)
  end

  def run_boom(kind: :run)
    kind == :run ? declare_action('boom') { raise 'kaboom' } : declare_query('boom') { raise 'kaboom' }
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
  # cart matched by (user_id, mandate_id, raw_jws), its intent and payment
  # matched by the FK chain AND their own raw_jws, then that cart's
  # settlement, if any. Drop the raw_jws comparisons and a mandate id re-used
  # with different content would be handed a settlement it did not buy.
  def chain_rows(stored, binds)
    user_id, cart_mandate_id, cart_jws, intent_jws, payment_jws = binds

    cart = stored_row(stored, 'cart_mandates', 'mandate_id' => cart_mandate_id, 'user_id' => user_id, 'raw_jws' => cart_jws)
    return [] if cart.nil?
    return [] unless stored_row(stored, 'intent_mandates', 'id' => cart['intent_mandate_id'], 'user_id' => user_id, 'raw_jws' => intent_jws)
    return [] unless stored_row(stored, 'payment_mandates', 'cart_mandate_id' => cart['id'], 'user_id' => user_id, 'raw_jws' => payment_jws)

    [chain_row(cart, stored['settlements'].find { |r| r['cart_mandate_id'] == cart['id'] } || {})]
  end

  def chain_row(cart, settlement)
    { 'cart_row' => cart['id'], 'declined_at' => cart['declined_at'], 'settlement_id' => settlement['id'],
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

  def record_decline(cart_row)
    stored['cart_mandates'].find { |r| r['id'] == cart_row }['declined_at'] = Time.current
    []
  end

  def record_insert(sql, binds)
    table = sql[/INSERT INTO \S+\.(\w+)/, 1]
    key   = [table, binds.first]
    raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint' \
      if inserted.include?(key)

    inserted << key
    id = "row-#{inserted.size}"
    stored[table] << ExecutorSpecHelpers::INSERT_COLUMNS.fetch(table).zip(binds).to_h.merge('id' => id)
    [{ 'id' => id }]
  end

  def stub_fresh_chain
    intent2, cart2, pay2 = fresh_chain
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent).and_return(intent2)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(cart2)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(pay2)
  end

  def fresh_chain
    [Kiosk::Mandate::IntentMandate.new(**intent.to_h, id: 'intent-2'),
     Kiosk::Mandate::CartMandate.new(**cart.to_h, id: 'cart-2', intent_mandate_id: 'intent-2'),
     Kiosk::Mandate::PaymentMandate.new(**payment.to_h, id: 'pay-2', cart_mandate_id: 'cart-2')]
  end
end

module ExecutorSpecCurrencyHelpers
  def sign(payload) = JWT.encode(payload, agent_key, 'RS256')

  def chain(currency)
    base = { iss: issuer, agent_id: 'agent-1', user_id: 'u-1', exp: future, iat: Time.now.to_i }
    { intent_mandate_jws: sign(base.merge(id: 'intent-1', scope: 'groceries',
                                          cap_amount_cents: 5000, currency: currency)),
      cart_mandate_jws: sign(base.merge(id: 'cart-1', intent_mandate_id: 'intent-1',
                                        line_items: [{ sku: 'pizza', qty: 1 }],
                                        total_amount_cents: 1599, currency: currency)),
      payment_mandate_jws: sign(base.merge(id: 'pay-1', cart_mandate_id: 'cart-1',
                                           payment_method: 'pm_card_visa',
                                           amount_cents: 1599, currency: currency)) }
  end

  def answered(currency)
    described_class.call(kind: :pay, args: chain(currency),
                         identity: identity, connection: connection).payload[:currency]
  end
end

RSpec.shared_context 'executor spec: fake connection' do
  include ExecutorSpecHelpers

  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: 'agent') }
end

RSpec.describe Kiosk::Server::Executor, '.call construction' do
  include_context 'executor spec: fake connection'

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

RSpec.describe Kiosk::Server::Executor, 'transaction discipline' do
  include_context 'executor spec: fake connection'

  it 'wraps the verb in a single transaction with GUCs set' do
    declare_query('probe') { render json: [{ ok: 1 }] }
    described_class.call(kind: :query, args: {}, name: 'probe', identity: identity, connection: connection)

    # 4 GUC statements only (the handler renders rows without hitting
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

RSpec.describe Kiosk::Server::Executor, 'verb :query' do
  include_context 'executor spec: fake connection'

  before do
    declare_query('menu') { render json: [{ 'id' => 1, 'name' => 'Margherita' }] }
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
    declare_query('items') { render json: [{ filter: params[:category] }] }
    result = described_class.call(
      kind: :query, args: { category: 'pizza' }, name: 'items',
      identity: identity, connection: connection
    )
    # String keys: a handler RENDERS, so the row makes a JSON round trip
    # before the Executor sees it — which is what reaches the agent.
    expect(result.payload).to eq([{ 'filter' => 'pizza' }])
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :query refusals' do
  include_context 'executor spec: fake connection'

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
    declare_query('denied') { raise Kiosk::Server::Errors::RLSDenied, 'no' }

    expect do
      described_class.call(kind: :query, args: {}, name: 'denied',
                           identity: identity, connection: connection)
    end.to raise_error(Kiosk::Server::Errors::RLSDenied)
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :query handler crash' do
  include_context 'executor spec: fake connection'

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
    declare_query('boom') { raise 'kaboom' }

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
RSpec.describe Kiosk::Server::Executor, 'verb :query pagination' do
  include_context 'executor spec: fake connection'

  it 'leaves next_cursor nil when the handler returns a bare Array (back-compat)' do
    declare_query('flat') { render json: [{ 'id' => 1 }, { 'id' => 2 }] }
    result = described_class.call(kind: :query, args: {}, name: 'flat',
                                  identity: identity, connection: connection)

    expect(result.kind).to        eq(:rows)
    expect(result.payload).to     eq([{ 'id' => 1 }, { 'id' => 2 }])
    expect(result.next_cursor).to be_nil
    expect(result.to_payload).to be_an(Array) # a bare array, like every query
  end

  it 'omits `next` when a paginating handler signals the last page (Page with nil cursor)' do
    declare_query('last') do
      render_kiosk_page([{ 'id' => 99 }]) # no next_cursor => complete
    end
    result = described_class.call(kind: :query, args: {}, name: 'last',
                                  identity: identity, connection: connection)

    expect(result.payload).to     eq([{ 'id' => 99 }])
    expect(result.next_cursor).to be_nil
    expect(result.to_payload).to be_an(Array) # a bare array, like every query
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :query next page' do
  include_context 'executor spec: fake connection'

  # T-092: the cursor reaches the RESULT, never the body. The wire turns it
  # into `Link: …; rel="next"`; the Executor's job ends at carrying it.
  it "threads a Page's next_cursor and total onto the Result, not into the body" do
    declare_query('paged') do
      offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
      render_kiosk_page([{ 'id' => offset + 1 }],
                        next_cursor: Kiosk::Server::Cursor.encode_offset(offset + 1),
                        total: 42)
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

RSpec.describe Kiosk::Server::Executor, 'verb :run' do
  include_context 'executor spec: fake connection'

  before do
    declare_action('ping') { render json: { pong: params[:greeting] } }
  end

  it 'looks up the action by name and calls it with sym-keyed args' do
    result = described_class.call(
      kind: :run, args: { greeting: 'world' }, name: 'ping',
      identity: identity, connection: connection
    )

    expect(result.kind).to    eq(:value)
    # String keys: the handler renders, so the value makes a JSON round trip.
    expect(result.payload).to eq('pong' => 'world')
  end

  it 'passes through args (except name) to the action handler' do
    declare_action('echo') { render json: { a: params[:a], b: params[:b] } }
    result = described_class.call(
      kind: :run, args: { a: 1, b: 'x' }, name: 'echo',
      identity: identity, connection: connection
    )
    expect(result.payload).to eq('a' => 1, 'b' => 'x')
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :run refusals' do
  include_context 'executor spec: fake connection'

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
    declare_action('denied') { raise Kiosk::Server::Errors::RLSDenied, 'no' }

    expect do
      described_class.call(kind: :run, args: {}, name: 'denied',
                           identity: identity, connection: connection)
    end.to raise_error(Kiosk::Server::Errors::RLSDenied)
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :run handler crash' do
  include_context 'executor spec: fake connection'

  # Same split as the query branch above, and it is asserted twice because
  # the two rescues are two pieces of code: a fix applied to one of them and
  # not the other is exactly the half-done shape this class keeps recurring
  # as.
  it 'wraps StandardError raised inside the action as ActionFailed' do
    declare_action('boom') { raise 'kaboom' }

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
RSpec.describe Kiosk::Server::Executor, "reporting a handler's crash to the operator" do
  include_context 'executor spec: fake connection'

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

RSpec.describe Kiosk::Server::Executor, "reporting a handler's crash safely" do
  include_context 'executor spec: fake connection'

  let(:logger) { instance_double(Logger, error: nil) }

  it 'BOUNDS the backtrace — a report is a pointer, not the whole stack' do
    allow(Rails).to receive(:logger).and_return(logger)
    declare_action('deep') do
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
end

RSpec.describe Kiosk::Server::Executor, "reporting a handler's crash safely" do
  include_context 'executor spec: fake connection'

  let(:logger) { instance_double(Logger, error: nil) }

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
    allow_any_instance_of(described_class).to receive(:warn).and_raise(IOError, 'stderr is gone')

    expect { run_boom }.to raise_error(Kiosk::Server::Errors::ActionFailed)
  end
end

# The `events` verb was removed (never a capability). It is
# now an unknown verb → a clean 400 BadRequest, not a raw NotImplementedError.
RSpec.describe Kiosk::Server::Executor, 'removed :events verb' do
  include_context 'executor spec: fake connection'

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
RSpec.describe Kiosk::Server::Executor, 'verb :schema (no longer dispatchable)' do
  include_context 'executor spec: fake connection'

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

RSpec.describe Kiosk::Server::Executor, 'verb :help (removed)' do
  include_context 'executor spec: fake connection'

  it 'is no longer a recognised verb' do
    expect do
      described_class.call(kind: :help, args: {}, identity: identity, connection: connection)
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb/)
  end
end

RSpec.shared_context 'executor spec: pay mandates' do
  include_context 'executor spec: fake connection'

  let(:identity) { build_identity(agent_id: 'a-1') }
  let(:intent) do
    Kiosk::Mandate::IntentMandate.new(
      id: 'intent-1', user_id: 'u-1', agent_id: 'a-1', issuer: 'https://demo.example',
      scope: 'groceries', cap_amount_cents: 5000, currency: 'eur',
      expires_at: nil, created_at: nil, raw_jws: 'intent-jws'
    )
  end
  let(:cart) do
    Kiosk::Mandate::CartMandate.new(
      id: 'cart-1', intent_mandate_id: 'intent-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', line_items: [{ sku: 'pizza', qty: 1 }],
      total_amount_cents: 1599, currency: 'eur', expires_at: nil, created_at: nil, raw_jws: 'cart-jws'
    )
  end
  let(:payment) do
    Kiosk::Mandate::PaymentMandate.new(
      id: 'pay-1', cart_mandate_id: 'cart-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', payment_method: 'pm_card_visa',
      amount_cents: 1599, currency: 'eur', expires_at: nil, created_at: nil, raw_jws: 'payment-jws'
    )
  end
end

RSpec.shared_context 'executor spec: verb :pay' do
  include_context 'executor spec: pay mandates'

  let(:settlement) { { psp_reference: 'pi_1', settled_amount_cents: 1599, settled_at: Time.current } }
  let(:valid_args) do
    { intent_mandate_jws: 'intent-jws', cart_mandate_jws: 'cart-jws', payment_mandate_jws: 'payment-jws' }
  end

  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.issuer = 'https://demo.example' }
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent)
      .with(raw_jws: 'intent-jws', identity: identity).and_return(intent)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart)
      .with(raw_jws: 'cart-jws', identity: identity, intent: intent).and_return(cart)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment)
      .with(raw_jws: 'payment-jws', identity: identity, cart: cart).and_return(payment)
    # Persist helpers return SERVER-generated ids (uuid PKs); the verb
    # threads them through the FK chain.
    { persist_intent_mandate: 'intent-row', persist_cart_mandate: 'cart-row',
      persist_payment_mandate: 'pay-row', persist_settlement: 's-1',
      in_flight_total_cents: 0, lock_assistant_payments!: nil, cart_recorded?: false }.each do |helper, value|
      allow_any_instance_of(described_class).to receive(helper).and_return(value)
    end
    Kiosk.configuration.payment_provider = instance_double('PSP', capture: settlement, setup_required?: false)
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay' do
  include_context 'executor spec: verb :pay'

  it 'verifies the trail, captures, and returns the full settlement payload' do
    result = pay
    expect(result.kind).to eq(:value)
    expect(result.payload).to include(
      settlement_id: 's-1',
      psp_reference: 'pi_1',
      settled_amount_cents: 1599,
      currency: 'eur'
    )
  end

  it 'threads the SERVER-generated intent id into the cart persist (FK chain, not the signed id)' do
    expect_any_instance_of(described_class).to receive(:persist_cart_mandate)
      .with(cart, intent_row_id: 'intent-row').and_return('cart-row')
    pay
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay' do
  include_context 'executor spec: verb :pay'

  it 'threads the SERVER-generated cart id into the payment mandate persist (FK chain)' do
    expect_any_instance_of(described_class).to receive(:persist_payment_mandate)
      .with(cart_row_id: 'cart-row', payment: payment).and_return('pay-row')
    pay
  end

  it 'threads the SERVER-generated cart id into the settlement persist (FK chain)' do
    expect_any_instance_of(described_class).to receive(:persist_settlement)
      .with(cart_row_id: 'cart-row', cart: cart, settled: settlement).and_return('s-1')
    pay
  end

  it 'passes the assistant-presented payment_method to capture' do
    expect(Kiosk.configuration.payment_provider).to receive(:capture)
      .with(cart, payment_method: 'pm_card_visa').and_return(settlement)
    pay
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay per-assistant spending cap' do
  include_context 'executor spec: verb :pay'

  it 'does not enforce when no spending_cap seam is configured (default)' do
    expect_any_instance_of(described_class).not_to receive(:spent_in_window)
    expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
    pay
  end

  it 'does not enforce for an assistant the seam reports uncapped (nil)' do
    Kiosk.configuration.spending_cap = ->(**) {}
    expect_any_instance_of(described_class).not_to receive(:spent_in_window)
    expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
    pay
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay per-assistant spending cap' do
  include_context 'executor spec: verb :pay'

  it 'proceeds when spent + cart total is within the cap' do
    Kiosk.configuration.spending_cap = ->(**) { 5000 }
    allow_any_instance_of(described_class).to receive(:spent_in_window).and_return(1000) # +1599 = 2599 <= 5000
    expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
    result = pay
    expect(result.kind).to eq(:value)
  end

  it 'rejects with SpendingCapExceeded (403) and does NOT capture when the cap would be exceeded' do
    Kiosk.configuration.spending_cap = ->(**) { 2000 }
    allow_any_instance_of(described_class).to receive(:spent_in_window).and_return(1000) # +1599 = 2599 > 2000
    expect(Kiosk.configuration.payment_provider).not_to receive(:capture)
    expect { pay }
      .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e| expect(e.http_status).to eq(403) }
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay spending cap tally' do
  include_context 'executor spec: verb :pay'

  it 'treats a cap of 0 as disabled (any charge rejected)' do
    Kiosk.configuration.spending_cap = ->(**) { 0 }
    allow_any_instance_of(described_class).to receive(:spent_in_window).and_return(0)
    expect(Kiosk.configuration.payment_provider).not_to receive(:capture)
    expect { pay }
      .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded)
  end

  it 'binds the acting agent_id, the cart currency and the window to the one tally statement' do
    Kiosk.configuration.spending_cap = ->(**) { 5000 }
    Kiosk.configuration.spending_cap_window_days = 7
    tally = nil
    route_exec_query(connection) do |sql, binds|
      tally = binds if sql.include?('AS total')
      [{ 'total' => 0 }]
    end
    pay
    expect(tally).to eq(['a-1', 'eur', 7])
  end

  # K-551: the tally must be scoped to the cart's currency — summing cents
  # across currencies is meaningless (4999 USD is not within a 5000 EUR cap),
  # and a cross-currency sum could erode the cap. The cart here is EUR.
  it "scopes the settled-total tally to the cart's currency (not currency-blind)" do
    Kiosk.configuration.spending_cap = ->(**) { 5000 }
    expect_any_instance_of(described_class).to receive(:spent_in_window)
      .with(having_attributes(currency: 'eur'), nil).and_return(0)
    pay
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay phase-1 errors' do
  include_context 'executor spec: verb :pay'

  # N2: a unique-violation surfacing from phase-1 persistence (same signed
  # mandate replayed) is a 409 Conflict, not a 500. Matched by class NAME so
  # the gem needn't load ActiveRecord in its own unit env.
  it 'maps a phase-1 unique violation to Errors::Conflict (409)' do
    stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))
    allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
      .and_raise(ActiveRecord::RecordNotUnique.new('dup key'))
    # K-850: the violation alone no longer decides the answer — the executor
    # asks whether THIS chain already settled. Here nothing did (the insert
    # never ran), so the settled-replay lookup finds no row and the 409 the
    # example is about is the one that reaches the caller.
    connection.next_exec_result = []

    expect { pay }
      .to raise_error(Kiosk::Server::Errors::Conflict) { |e| expect(e.http_status).to eq(409) }
  end

  it 'lets a non-unique phase-1 error propagate unchanged (not remapped to Conflict)' do
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart)
      .and_raise(Kiosk::Server::Errors::Forbidden.new('cart exceeds intent cap'))

    expect { pay }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /cap/)
  end

  # An agentless principal (user_idp web/mobile session, agent_id nil)
  # cannot pay — mandates are agent-signed. Reject with a clean
  # 403, not a 500 from agent_payment_key(nil) deep in mandate verification.
  it 'rejects an agentless caller (agent_id nil) with a clean 403 before verifying mandates' do
    agentless = build_identity(actor: 'human', agent_id: nil)
    expect(Kiosk::Server::MandateVerifier).not_to receive(:verify_intent)

    expect { pay(as: agentless) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /agent identity/) { |e| expect(e.http_status).to eq(403) }
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay capture placement' do
  include_context 'executor spec: verb :pay'

  it 'does not capture when phase-1 persistence raises a unique violation' do
    stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))
    allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
      .and_raise(ActiveRecord::RecordNotUnique.new('dup key'))
    connection.next_exec_result = [] # no settlement for this chain (K-850)
    provider = Kiosk.configuration.payment_provider
    expect(provider).not_to receive(:capture)

    expect { pay }
      .to raise_error(Kiosk::Server::Errors::Conflict)
  end

  # C2: an irreversible PSP capture must never run inside a DB transaction —
  # a ROLLBACK cannot undo a Stripe charge. FakeConnection tracks tx depth.
  it 'captures OUTSIDE any DB transaction' do
    in_tx_at_capture = nil
    Kiosk.configuration.payment_provider = instance_double('PSP')
    allow(Kiosk.configuration.payment_provider).to receive(:setup_required?).and_return(false)
    allow(Kiosk.configuration.payment_provider).to receive(:capture) do |_cart, **_kwargs|
      in_tx_at_capture = connection.in_transaction?
      settlement
    end

    pay
    expect(in_tx_at_capture).to be(false)
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay payment setup' do
  include_context 'executor spec: verb :pay'

  # I-1: provider.setup_required? == true → clean 402 BEFORE Phase 1 persists
  # anything.  No mandate ids are burned, so the agent can retry after the
  # human completes the SetupIntent flow without hitting the UNIQUE idempotency key.
  it 'raises PaymentSetupRequired (402) before persisting mandates when provider.setup_required? is true' do
    provider = instance_double('PSP', setup_required?: true)
    Kiosk.configuration.payment_provider = provider

    # Phase 1 mandate verification must not run — no mandate burning.
    expect(Kiosk::Server::MandateVerifier).not_to receive(:verify_intent)

    expect do
      pay
    end.to raise_error(Kiosk::Server::Errors::PaymentSetupRequired) { |e|
      expect(e.http_status).to eq(402)
      expect(e.code).to        eq('payment_setup_required')
    }
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

RSpec.describe Kiosk::Server::Executor, 'verb :pay capture failure' do
  include_context 'executor spec: verb :pay'

  # K-545: a card DECLINE (retryable PaymentFailed) becomes a typed
  # `payment_failed` 402, NOT a raw 500. The mandate trail is already
  # persisted; the message is the adapter's human-safe string (no PSP
  # internals) and the hint tells the agent it is safe to retry.
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
  # is also a typed 402; its hint sends the SAME chain again, which the
  # operator charges at most once.
  it 'maps a non-retryable capture-time PaymentFailed to a 402 whose hint sends the same chain again' do
    fail_capture('the payment processor could not confirm the charge; its status is unknown',
                 retryable: false)

    expect do
      pay
    end.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
      expect(e.http_status).to eq(402)
      expect(e.code).to        eq('payment_failed')
      expect(e.hint).to        match(/Send the SAME chain again/)
      expect(e.hint).to        match(/Do not sign a new chain/)
    }
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay missing mandates' do
  include_context 'executor spec: verb :pay'

  it 'raises BadRequest when intent_mandate_jws is missing' do
    expect do
      pay({ cart_mandate_jws: 'cart-jws', payment_mandate_jws: 'payment-jws' })
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /intent_mandate_jws/)
  end

  it 'raises BadRequest when cart_mandate_jws is missing' do
    expect do
      pay({ intent_mandate_jws: 'intent-jws', payment_mandate_jws: 'payment-jws' })
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /cart_mandate_jws/)
  end

  it 'raises BadRequest when payment_mandate_jws is missing' do
    expect do
      pay({ intent_mandate_jws: 'intent-jws', cart_mandate_jws: 'cart-jws' })
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /payment_mandate_jws/)
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay without a payment provider' do
  include_context 'executor spec: verb :pay'

  # T-158: `module_not_served` (501), not `forbidden` (403). "This origin does
  # not do payments" is a fact about the ORIGIN and is true of every caller,
  # while `forbidden` is glossed "authenticated, but this identity may not do
  # this" — the mis-fit K-1207 measured and decision «A» split.
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

  # K-800: THE ORIGIN ANSWERS BEFORE THE ARGUMENTS DO. `pay` is drawn on every
  # mounted host, and a host with no payment_provider answers it with
  # `module_not_served` at 501 — but the three mandate guards used to run
  # first, so an empty POST at a payment-free origin came back `400
  # args.intent_mandate_jws required`: an instruction to sign three mandates,
  # from an origin that could never settle them. The example sends NO
  # arguments at all, which is exactly the case that wrong order got wrong.
  it 'answers a payment-free origin with module_not_served even when NO mandates are sent (K-800)' do
    Kiosk.configuration.payment_provider = nil
    expect { pay({}) }
      .to raise_error(Kiosk::Server::Errors::ModuleNotServed, /does not serve the payment module/)
  end
end

# ── Replay: the mandate chain IS the idempotency key (K-739) ───────────
#
# `pay` publishes no idempotency header and no idempotency field, and the
# spec (protocol.md §11.6) now says why it needs none: the three mandate
# `id`s already are one, and an assistant whose `pay` response was lost
# retries with the IDENTICAL chain. These examples pin BOTH halves of the
# behaviour that claim rests on — the safe path and the unsafe one — at the
# only layer where "how many times was the card charged" is observable
# without a database.
#
# The persist helpers run FOR REAL here (the enclosing `before` stubs them;
# this context calls them through) against a router that enforces the
# constraint the shipped schema declares: `UNIQUE (user_id, mandate_id)` on
# each of the three mandate tables. So the 409 is produced by the same
# `unique_violation?` remap a real Postgres would trip, not by a stub.
RSpec.shared_context 'executor spec: replayed with the identical mandate chain' do
  include_context 'executor spec: verb :pay'
  include ExecutorSpecReplayHelpers

  # `[table, mandate_id]` for every mandate row the router has accepted —
  # the in-memory stand-in for `UNIQUE (user_id, mandate_id)`. One
  # principal per example, so the mandate id alone is the whole key.
  let(:inserted) { [] }
  let(:captures) { [] }
  # The rows those inserts wrote, by table, each as a column=>value hash
  # plus the server id the statement returned. K-850's replay lookup is a
  # READ, so a router that answers it has to have kept what was written.
  let(:stored) { Hash.new { |h, k| h[k] = [] } }

  before do
    stub_const('ActiveRecord::RecordNotUnique', Class.new(StandardError))

    %i[persist_intent_mandate persist_cart_mandate
       persist_payment_mandate persist_settlement].each do |helper|
      allow_any_instance_of(described_class).to receive(helper).and_call_original
    end

    route_mandate_tables

    Kiosk.configuration.payment_provider = instance_double('PSP', setup_required?: false)
    %i[capture resume].each do |call|
      allow(Kiosk.configuration.payment_provider).to receive(call) do |cart, **_kwargs|
        captures << cart.id
        settlement
      end
    end
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay replayed with the identical mandate chain' do
  include_context 'executor spec: replayed with the identical mandate chain'

  # THE ONE-CHARGE ASSERTION, and since K-850 also the IDEMPOTENCE one.
  # Same args, twice: the second call re-presents `intent-1`, the row is
  # already there, and the unique violation lands in phase 1 — BEFORE phase
  # 2 — where the executor asks whether THIS chain already settled. It did,
  # so the replay is answered with the settlement the first call returned.
  # The card is charged exactly once and no second settlement is minted.
  it 'charges once and replays the ORIGINAL settlement the second time (K-850)' do
    first = pay
    expect(first.payload).to include(settlement_id: 'row-4')

    second = pay

    expect(second.kind).to eq(:value)
    expect(second.payload).to eq(first.payload)
    expect(captures).to eq(['cart-1'])
    expect(inserted.count { |table, _| table == 'settlements' }).to eq(1)
  end

  # A `409` on a replay would not have been idempotence — it would have been
  # a different answer to the same request, and one carrying none of the
  # settlement facts the assistant is missing. Pinned as its own example so
  # the regression reads as what it is.
  it 'does not answer a settled replay with an error at all (K-850)' do
    pay

    expect do
      pay
    end.not_to raise_error
  end

  # THE REACHABLE DOUBLE CHARGE, pinned so nobody has to take §11.6's word
  # for it. A client that answers a lost response by MINTING A FRESH CHAIN
  # collides with nothing: new `id`s, new rows, a second capture. Nothing in
  # the engine can tell this from a genuine second purchase — which is
  # exactly why the rule "retry the identical chain, never a fresh one"
  # lives in the spec and in skill.md rather than in the executor.
  it 'charges TWICE when the retry mints a fresh chain (the case §11.6 forbids)' do
    pay

    stub_fresh_chain

    pay

    expect(captures).to eq(%w[cart-1 cart-2])
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay replay boundary' do
  include_context 'executor spec: replayed with the identical mandate chain'

  # A chain whose charge was declined is closed: no money moved under it, and
  # a repeat answers `409 conflict` before any capture.
  it 'answers 409 conflict to a repeat of a declined chain' do
    allow(Kiosk.configuration.payment_provider).to receive(:capture)
      .and_raise(Kiosk::PaymentProviders::PaymentFailed.new('declined', retryable: true))
    expect do
      pay
    end.to raise_error(Kiosk::Server::Errors::PaymentFailed)

    expect do
      pay
    end.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
      expect(e.http_status).to eq(409)
      expect(e.code).to        eq('conflict')
    }
    expect(inserted.count { |table, _| table == 'settlements' }).to eq(0)
  end

  # AND THE OTHER HALF OF THE BOUNDARY: a settled cart `id` re-presented
  # with DIFFERENT signed bytes is not this request, so it is not handed
  # this request's settlement.
  it 'refuses a settled cart id re-presented with different bytes (K-850)' do
    pay
    tampered = Kiosk::Mandate::CartMandate.new(**cart.to_h, raw_jws: 'cart-jws-TAMPERED')
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(tampered)
    allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(payment)

    expect do
      pay
    end.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
    expect(captures).to eq(['cart-1'])
  end
end

RSpec.describe Kiosk::Server::Executor, 'verb :pay phase-3 window' do
  include_context 'executor spec: replayed with the identical mandate chain'

  # The capture succeeds and phase 3 — the transaction that records it —
  # fails. The identical chain sent again charges under the same cart id,
  # which the PSP's idempotency key turns into the first charge's answer,
  # and writes the missing settlement.
  it 'resumes a chain whose capture ran but whose settlement was never written' do
    allow_any_instance_of(described_class).to receive(:persist_settlement)
      .and_raise(StandardError, 'connection reset during settlement insert')
    expect { pay }.to raise_error(StandardError, /connection reset/)
    expect(inserted.map(&:first)).not_to include('settlements')

    allow_any_instance_of(described_class).to receive(:persist_settlement).and_call_original
    result = pay

    expect(result.payload).to include(psp_reference: 'pi_1', settled_amount_cents: 1599)
    expect(captures).to eq(%w[cart-1 cart-1])
    expect(Kiosk.configuration.payment_provider).to have_received(:resume).once
    expect(inserted.count { |table, _| table == 'settlements' }).to eq(1)
  end
end

# ── The pay path's statements carry BIND PARAMETERS, not spliced values ───
#
# K-654: these four INSERTs (and the spending-cap SELECT) used to be heredocs
# with every field run through a private `q()` = `connection.quote`. This
# group asserts the shape that replaced it — `$N` placeholders, values handed
# over separately and in order — and, above all, that `connection.quote` is
# not reachable from the pay path at all. A quoted value inside an assembled
# string is safe exactly as long as nobody forgets one; there is now nothing
# to forget, and that is the property worth a test.
#
# What this group deliberately does NOT claim is that the values are STORED
# correctly: a fake connection cannot know what Postgres makes of a bind's
# type. That is `executor_persistence_spec.rb`, against a real database.
RSpec.shared_context 'executor spec: dated mandates' do
  include_context 'executor spec: fake connection'

  let(:expires_at) { Time.at(1_800_000_071).utc }
  let(:intent) do
    Kiosk::Mandate::IntentMandate.new(
      id: 'intent-1', user_id: 'u-1', agent_id: 'a-1', issuer: 'https://demo.example',
      scope: 'groceries', cap_amount_cents: 5000, currency: 'eur',
      expires_at: expires_at, created_at: expires_at, raw_jws: 'intent-jws'
    )
  end
  let(:cart) do
    Kiosk::Mandate::CartMandate.new(
      id: 'cart-1', intent_mandate_id: 'intent-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', line_items: [{ 'sku' => 'pizza', 'qty' => 1 }],
      total_amount_cents: 1599, currency: 'eur', expires_at: expires_at,
      created_at: expires_at, raw_jws: 'cart-jws'
    )
  end
  let(:payment) do
    Kiosk::Mandate::PaymentMandate.new(
      id: 'pay-1', cart_mandate_id: 'cart-1', user_id: 'u-1', agent_id: 'a-1',
      issuer: 'https://demo.example', payment_method: 'pm_card_visa',
      amount_cents: 1599, currency: 'eur', expires_at: expires_at,
      created_at: expires_at, raw_jws: 'payment-jws'
    )
  end
end

RSpec.shared_context 'executor spec: pay-path persistence (bind parameters)' do
  include_context 'executor spec: dated mandates'

  subject(:executor) { described_class.new(connection: connection, identity: identity) }

  before { Kiosk.configure { |c| c.schema = 'kiosk' } }
end

RSpec.describe Kiosk::Server::Executor, 'pay-path mandate inserts' do
  include_context 'executor spec: pay-path persistence (bind parameters)'

  it 'binds every intent-mandate value and splices none of them into the SQL' do
    id = executor.send(:persist_intent_mandate, intent)
    sql, name, binds = last_statement

    expect(id).to   eq('row-1') # the RETURNING id the fake hands back
    expect(name).to eq('Kiosk intent_mandate insert')
    expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9)')
    expect(binds).to eq([
                          'intent-1', 'u-1', 'a-1', 'https://demo.example', 'groceries',
                          5000, 'eur', expires_at, 'intent-jws'
                        ])
  end

  it 'binds every cart-mandate value, with line_items as JSON text under an explicit ::jsonb cast' do
    executor.send(:persist_cart_mandate, cart, intent_row_id: 'intent-row')
    sql, name, binds = last_statement

    expect(name).to eq('Kiosk cart_mandate insert')
    expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)')
    expect(binds).to eq([
                          'cart-1', 'intent-row', 'u-1', 'a-1', 'https://demo.example',
                          %([{"sku":"pizza","qty":1}]), 1599, 'eur', expires_at, 'cart-jws'
                        ])
  end
end

RSpec.describe Kiosk::Server::Executor, 'pay-path payment and settlement inserts' do
  include_context 'executor spec: pay-path persistence (bind parameters)'

  it 'binds every payment-mandate value' do
    executor.send(:persist_payment_mandate, cart_row_id: 'cart-row', payment: payment)
    sql, name, binds = last_statement

    expect(name).to eq('Kiosk payment_mandate insert')
    expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)')
    expect(binds).to eq([
                          'pay-1', 'cart-row', 'u-1', 'a-1', 'https://demo.example',
                          'pm_card_visa', 1599, 'eur', expires_at, 'payment-jws'
                        ])
  end

  it "binds the 'on_file' sentinel rather than an empty payment_method" do
    on_file = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, payment_method: '')
    executor.send(:persist_payment_mandate, cart_row_id: 'cart-row', payment: on_file)

    expect(last_statement[2][5]).to eq('on_file')
  end

  it 'binds every settlement value' do
    executor.send(:persist_settlement, cart_row_id: 'cart-row', cart: cart,
                                       settled: { psp_reference: 'pi_1', settled_amount_cents: 1599 })
    sql, name, binds = last_statement

    expect(name).to eq('Kiosk settlement insert')
    expect(sql).to  include('VALUES ($1, $2, $3, $4, $5, $6, $7, now())')
    expect(binds).to eq(['cart-row', 'u-1', 'a-1', 'https://demo.example', 'pi_1', 1599, 'eur'])
    # K-948: no `raw_jws` column, so no literal `''` trailing the VALUES list.
    # Asserted on the COLUMN list as well, because a statement that still
    # named the column while binding nothing would satisfy the line above.
    expect(sql).not_to include('raw_jws')
  end
end

RSpec.describe Kiosk::Server::Executor, 'pay-path persistence (bind parameters)' do
  include_context 'executor spec: pay-path persistence (bind parameters)'

  # The regression guard the row is actually about: no value — not even a
  # harmless one — may appear in the statement text, and `quote` must never
  # be called. Written over all four helpers so a future fifth statement
  # that forgets is caught by the same assertion.
  it 'never calls connection.quote and never lets a value reach the SQL text' do
    expect(connection).not_to receive(:quote)

    intent_row = executor.send(:persist_intent_mandate, intent)
    cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
    executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: payment)
    executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart,
                                       settled: { psp_reference: 'pi_1', settled_amount_cents: 1599 })

    expect(connection.exec_queries.size).to eq(4)
    connection.exec_queries.each do |sql, _name, binds|
      binds.each do |value|
        next if value.is_a?(Integer) # a bare number is not evidence of splicing

        expect(sql).not_to include(value.to_s)
      end
    end
  end
end

RSpec.describe Kiosk::Server::Executor, 'pay-path #settled_total_cents' do
  include_context 'executor spec: pay-path persistence (bind parameters)'

  before { connection.next_exec_result = [{ 'total' => 0 }] }

  it 'binds the agent and the currency, with no window predicate when uncapped by time' do
    executor.send(:settled_total_cents, agent_id: 'a-1', window_days: nil, currency: 'eur')
    sql, name, binds = last_statement

    expect(name).to eq('Kiosk settled total')
    # K-1251: the predicate folds the COLUMN, for settlement rows written
    # before the mandate boundary canonicalised what fills it.
    expect(sql).to  include('WHERE agent_id = $1 AND lower(btrim(currency)) = $2')
    expect(sql).not_to include('settled_at')
    expect(binds).to eq(%w[a-1 eur])
  end

  # The window used to be `#{window_days.to_i} * INTERVAL '1 day'` — the
  # last interpolation in the file, and the one the third-party review
  # missed. It is a bind now.
  it 'binds the window length rather than interpolating the day count' do
    executor.send(:settled_total_cents, agent_id: 'a-1', window_days: 7, currency: 'eur')
    sql, _name, binds = last_statement

    expect(sql).to include('AND settled_at >= now() - make_interval(days => $3)')
    expect(sql).not_to include('7')
    expect(binds).to eq(['a-1', 'eur', 7])
  end

  # K-1251: the BIND is folded too, so a caller that hands over a cart the
  # verifier never canonicalised still reads the same tally.
  it 'canonicalises the currency it binds' do
    executor.send(:settled_total_cents, agent_id: 'a-1', window_days: nil, currency: ' EUR ')
    _sql, _name, binds = last_statement

    expect(binds).to eq(%w[a-1 eur])
  end
end

RSpec.shared_context 'executor spec: really signed chain' do
  include ExecutorSpecCurrencyHelpers

  let(:agent_key)  { OpenSSL::PKey::RSA.generate(2048) }
  let(:issuer)     { 'https://demo.example' }
  let(:identity)   { build_identity(agent_id: 'agent-1', user_id: 'u-1') }
  let(:future)     { (Time.current + 600).to_i }
  let(:connection) { FakeConnection.new }

  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.issuer = issuer }
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:agent_payment_key).with('agent-1').and_return(agent_key.public_key)
    allow(Kiosk::Server::SessionContext).to receive(:open) { |**_kw, &blk| blk.call }
    { persist_intent_mandate: 'intent-row', persist_cart_mandate: 'cart-row',
      persist_payment_mandate: 'pay-row', persist_settlement: 's-1' }.each do |helper, value|
      allow_any_instance_of(described_class).to receive(helper).and_return(value)
    end
    Kiosk.configuration.payment_provider = instance_double(
      'PSP',
      capture: { psp_reference: 'pi_1', settled_amount_cents: 1599, settled_at: Time.current },
      setup_required?: false
    )
  end
end

# The currency `pay` ANSWERS with is the operator's canonical one. The
# `verb :pay` groups stub `MandateVerifier.verify_*`, so this group runs the
# REAL verifier on a really signed chain and reads the answer.
RSpec.describe Kiosk::Server::Executor, 'the currency a `pay` answers with (§11.3, K-1257)' do
  include_context 'executor spec: really signed chain'

  it 'answers `eur` to a chain signed `EUR` throughout' do
    expect(answered('EUR')).to eq('eur')
  end

  it 'answers `eur` to a chain signed `  EUR ` throughout' do
    expect(answered('  EUR ')).to eq('eur')
  end

  # The already-canonical case is here so the two above cannot be read as
  # "the answer is always eur because the fixture says eur": this one is the
  # control, and it is the only one where the answer equals the input bytes.
  it 'answers `eur` to a chain already signed `eur`, which is the only case where the bytes match' do
    expect(answered('eur')).to eq('eur')
  end
end
