# frozen_string_literal: true

# A Kiosk::Identity-shaped double: this gem does not depend on kiosk-core.
BackoffIdentity = Struct.new(:agent_id, :user_id) do
  def to_s = 'BackoffIdentity'
end

RSpec.shared_context 'with a backoff policy' do
  subject(:policy) { described_class.new(count: 3, base:) }

  let(:base) { { alg: 'equihash', params: { n: 96, k: 5 }, count: 1 } }

  def ask(identity, asked = policy)
    asked.challenge_for(identity:, verb: :query, factors: nil)
  end
end

RSpec.describe Kiosk::Reputation::Policies::Backoff, 'with no grant yet' do
  include_context 'with a backoff policy'

  it 'challenges (returns a dup of base) on the very first request' do
    expect(ask('agent-1')).to eq(base)
  end

  it 'keeps challenging on every request while ungranted' do
    3.times { expect(ask('agent-1')).to eq(base) }
  end

  it 'returns a distinct dup each time (not the frozen internal base)' do
    spec = ask('agent-1')
    expect(spec).not_to be_frozen
    expect { spec[:count] = 9 }.not_to raise_error
  end

  it 'is a Kiosk::Reputation::Policy' do
    expect(policy).to be_a(Kiosk::Reputation::Policy)
  end
end

RSpec.describe Kiosk::Reputation::Policies::Backoff, 'after on_proof_verified' do
  include_context 'with a backoff policy'

  it 'serves the next `count` requests without a challenge, then re-challenges' do
    policy.on_proof_verified(identity: 'agent-1')
    expect(Array.new(4) { ask('agent-1') }).to eq([nil, nil, nil, base])
  end

  it "grants are per-identity (agent-2's solve does not free agent-1)" do
    policy.on_proof_verified(identity: 'agent-2')
    expect(ask('agent-1')).to eq(base)
    expect(ask('agent-2')).to be_nil
  end

  it 'a fresh solve mid-burst resets the count back to `count`' do
    policy.on_proof_verified(identity: 'agent-1')
    expect(ask('agent-1')).to be_nil
    policy.on_proof_verified(identity: 'agent-1')
    expect(Array.new(4) { ask('agent-1') }).to eq([nil, nil, nil, base])
  end
end

RSpec.describe Kiosk::Reputation::Policies::Backoff, 'identity key' do
  include_context 'with a backoff policy'

  it 'keys a Kiosk::Identity-shaped object by agent_id when present' do
    policy.on_proof_verified(identity: BackoffIdentity.new('agent-x', 'user-1'))
    expect(ask(BackoffIdentity.new('agent-x', 'user-1'))).to be_nil
  end

  it 'falls back to user_id when agent_id is nil' do
    policy.on_proof_verified(identity: BackoffIdentity.new(nil, 'user-42'))
    expect(ask(BackoffIdentity.new(nil, 'user-42'))).to be_nil
    expect(ask(BackoffIdentity.new(nil, 'user-99'))).to eq(base)
  end

  it 'distinguishes two agents of the same user by agent_id' do
    policy.on_proof_verified(identity: BackoffIdentity.new('agent-A', 'user-1'))
    expect(ask(BackoffIdentity.new('agent-B', 'user-1'))).to eq(base)
  end

  it 'keys a plain string identity by its own value' do
    policy.on_proof_verified(identity: 'opaque-token')
    expect(ask('opaque-token')).to be_nil
    expect(ask('other-token')).to eq(base)
  end

  it 'delegates consume/grant to an injected store' do
    shared = Kiosk::Reputation::BackoffStore.new
    described_class.new(count: 2, base:, store: shared).on_proof_verified(identity: 'agent-1')
    expect(ask('agent-1', described_class.new(count: 2, base:, store: shared))).to be_nil
  end
end

RSpec.describe Kiosk::Reputation::Policies::Backoff, 'constructor validation' do
  include_context 'with a backoff policy'

  it 'rejects count < 1' do
    expect { described_class.new(count: 0, base:) }.to raise_error(ArgumentError, /count must be >= 1/)
  end

  it 'coerces a numeric-string count' do
    two = described_class.new(count: '2', base:)
    two.on_proof_verified(identity: 'a')
    expect(Array.new(3) { ask('a', two) }).to eq([nil, nil, base])
  end

  it 'rejects a base without :alg' do
    expect { described_class.new(count: 1, base: { params: { n: 96, k: 5 } }) }
      .to raise_error(ArgumentError, /base must be a challenge spec/)
  end

  it 'rejects a base without :params' do
    expect { described_class.new(count: 1, base: { alg: 'equihash' }) }
      .to raise_error(ArgumentError, /base must be a challenge spec/)
  end

  it 'rejects a non-Hash base' do
    expect { described_class.new(count: 1, base: 'nope') }
      .to raise_error(ArgumentError, /base must be a challenge spec/)
  end
end
