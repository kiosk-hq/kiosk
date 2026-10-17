# frozen_string_literal: true

RSpec.shared_context 'with a null executor' do
  subject(:executor) { described_class.new }

  let(:identity) { Kiosk::Identity.new(user_id: 'u1', role: 'customer', actor: 'human') }
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#with_identity' do
  include_context 'with a null executor'

  it 'pushes and pops the identity stack around the block' do
    observed = nil
    executor.with_identity(identity) { observed = executor.current_identity }
    expect(observed).to eq(identity)
    expect(executor.current_identity).to be_nil
  end

  it 'pops even when the block raises' do
    expect do
      executor.with_identity(identity) { raise 'boom' }
    end.to raise_error('boom')
    expect(executor.current_identity).to be_nil
  end

  it 'supports nested scopes' do
    outer = identity
    inner = Kiosk::Identity.new(user_id: 'u2', role: 'customer', actor: 'human')

    observed = []
    executor.with_identity(outer) do
      observed << executor.current_identity
      executor.with_identity(inner) { observed << executor.current_identity }
      observed << executor.current_identity
    end

    expect(observed).to eq([outer, inner, outer])
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#query' do
  include_context 'with a null executor'

  it 'records the call with the current identity' do
    executor.with_identity(identity) { executor.query('select 1') }
    call = executor.calls.first
    expect(call.kind).to     eq(:query)
    expect(call.args).to     eq(sql: 'select 1')
    expect(call.identity).to eq(identity)
  end

  it 'returns [] by default' do
    expect(executor.query('select 1')).to eq([])
  end

  it 'returns the queued result FIFO' do
    executor.enqueue_query([{ 'n' => 1 }])
    executor.enqueue_query([{ 'n' => 2 }])
    expect(executor.query('a')).to eq([{ 'n' => 1 }])
    expect(executor.query('b')).to eq([{ 'n' => 2 }])
  end

  it 'raises RLSDenied when an error is enqueued' do
    executor.enqueue_error(:query, :rls_denied)
    expect { executor.query('x') }
      .to raise_error(Kiosk::TestHelpers::Errors::RLSDenied)
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#run_action' do
  include_context 'with a null executor'

  it 'records name + args' do
    executor.run_action(:create_order, { items: ['bread'] })
    call = executor.calls_of(:run_action).first
    expect(call.args).to eq(name: :create_order, args: { items: ['bread'] })
  end

  it 'raises QuotaExceeded when enqueued' do
    executor.enqueue_error(:run_action, :quota_exceeded)
    expect { executor.run_action(:x, {}) }
      .to raise_error(Kiosk::TestHelpers::Errors::QuotaExceeded)
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#run_query' do
  include_context 'with a null executor'

  it 'records name + args under its own kind' do
    executor.run_query(:my_orders, { since: '2026-01-01' })
    call = executor.calls_of(:run_query).first
    expect(call.args).to eq(name: :my_orders, args: { since: '2026-01-01' })
    expect(executor.calls_of(:run_action)).to be_empty
  end

  # K-1706. THE ONE BEHAVIOUR THAT SEPARATES THE READ SIDE FROM THE ACTION
  # KINDS: `default_for` answers [] for a read and nil for a write, so a verb
  # declared `kind :query` yields rows rather than nothing when no result was
  # queued. The pay_action example below is the control for the other half.
  it 'returns [] by default, as the READ side does and the action kinds do not' do
    expect(executor.run_query(:my_orders, {})).to eq([])
    expect(executor.run_action(:x, {})).to be_nil
  end

  it 'returns the queued result FIFO via enqueue_run_query' do
    executor.enqueue_run_query([{ 'id' => 1 }])
    executor.enqueue_run_query([{ 'id' => 2 }])
    expect(executor.run_query(:my_orders, {})).to eq([{ 'id' => 1 }])
    expect(executor.run_query(:my_orders, {})).to eq([{ 'id' => 2 }])
  end

  it 'raises RLSDenied when an error is enqueued' do
    executor.enqueue_error(:run_query, :rls_denied)
    expect { executor.run_query(:my_orders, {}) }
      .to raise_error(Kiosk::TestHelpers::Errors::RLSDenied)
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#pay_action' do
  include_context 'with a null executor'

  it 'records under its own kind' do
    executor.pay_action(:buy, { sku: 'x' })
    expect(executor.calls_of(:pay_action).size).to eq(1)
    expect(executor.calls_of(:run_action)).to be_empty
  end

  it 'returns nil by default' do
    expect(executor.pay_action(:buy, { sku: 'x' })).to be_nil
  end

  it 'returns the queued result FIFO via enqueue_pay_action' do
    executor.enqueue_pay_action({ 'status' => 'captured' })
    executor.enqueue_pay_action({ 'status' => 'declined' })
    expect(executor.pay_action(:buy, {})).to eq('status' => 'captured')
    expect(executor.pay_action(:buy, {})).to eq('status' => 'declined')
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#seed' do
  include_context 'with a null executor'

  it 'records table, attrs, count' do
    executor.seed(:rentals, { active: true }, count: 3)
    call = executor.calls_of(:seed).first
    expect(call.args).to eq(table: :rentals, attrs: { active: true }, count: 3)
  end

  it 'returns nil by default' do
    expect(executor.seed(:rentals, { active: true }, count: 1)).to be_nil
  end

  it 'returns the queued result FIFO via enqueue_seed' do
    executor.enqueue_seed([{ 'id' => 1 }])
    executor.enqueue_seed([{ 'id' => 2 }])
    expect(executor.seed(:rentals, {}, count: 1)).to eq([{ 'id' => 1 }])
    expect(executor.seed(:rentals, {}, count: 1)).to eq([{ 'id' => 2 }])
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, '#calls_of' do
  include_context 'with a null executor'

  it 'filters by kind' do
    executor.query('a')
    executor.run_action(:x, {})
    executor.query('b')
    expect(executor.calls_of(:query).size).to       eq(2)
    expect(executor.calls_of(:run_action).size).to  eq(1)
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, 'enqueued errors with custom class' do
  include_context 'with a null executor'

  it 'raises any provided exception class' do
    custom = Class.new(StandardError)
    executor.enqueue_error(:query, custom)
    expect { executor.query('x') }.to raise_error(custom)
  end
end

# The rig helper names are derived from the executor, not typed here. Each verb
# is invoked once on a fresh rig; the `kind` it stamps on the recorded Call is
# read back off `calls.last`, and the helper that must queue for it is spelled
# `"enqueue_#{kind}"`. A list of helper names in a spec could repeat a wrong
# name; only the kind read off the rig catches it.
#
# The invocation table is written by hand, so the roll-call example holds the
# class to `public_instance_methods(false)`: any public method the class gains
# or loses fails it and must be placed by hand.
module NullExecutorVerbs
  # Invocations, not assertions. The key is the verb method the lambda calls.
  # It is never used as the kind; the kind is always read back off the rig.
  INVOCATIONS = {
    'query' => ->(x) { x.query('select 1') },
    'run_query' => ->(x) { x.run_query(:rooms, {}) },
    'run_action' => ->(x) { x.run_action(:book, {}) },
    'pay_action' => ->(x) { x.pay_action(:buy, {}) },
    'seed' => ->(x) { x.seed(:rooms, {}, count: 1) }
  }.freeze

  def self.kind_recorded_by(invoke)
    probe = Kiosk::TestHelpers::NullExecutor.new
    invoke.call(probe)
    probe.calls.last.kind
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, 'the enqueue_<kind> naming rule' do
  include_context 'with a null executor'

  NullExecutorVerbs::INVOCATIONS.each do |verb, invoke|
    it "queues for ##{verb} through the helper named after the kind it records" do
      expect(executor).to respond_to(verb)

      helper = "enqueue_#{NullExecutorVerbs.kind_recorded_by(invoke)}"
      expect(executor).to respond_to(helper)

      # The helper must queue for THAT verb: a name that exists but queues for
      # a different kind is the same defect with a correct spelling.
      rig = described_class.new
      rig.public_send(helper, :sentinel)
      expect(invoke.call(rig)).to eq(:sentinel)
    end
  end
end

RSpec.describe Kiosk::TestHelpers::NullExecutor, 'public surface' do
  include_context 'with a null executor'

  # `enqueue_error` is the one helper that is not per kind: it takes the kind as
  # its first argument. The rest of the tail is the rig's reading surface.
  it 'has one public method per verb, per kind helper, and per named reader — and no others' do
    kinds = NullExecutorVerbs::INVOCATIONS.values.map { |invoke| NullExecutorVerbs.kind_recorded_by(invoke) }
    expect(kinds.uniq.size).to eq(NullExecutorVerbs::INVOCATIONS.size)
    expect(described_class.public_instance_methods(false).map(&:to_s))
      .to match_array(NullExecutorVerbs::INVOCATIONS.keys + kinds.map { |kind| "enqueue_#{kind}" } +
                      %w[enqueue_error with_identity calls calls_of current_identity])
  end

  # A rig user asks for the current identity; the identity a call ran under is
  # stamped on the recorded Call.
  it 'does not expose the identity stack' do
    expect(executor).not_to respond_to(:identity_stack)
  end
end
