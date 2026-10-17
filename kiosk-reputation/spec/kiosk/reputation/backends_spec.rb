# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Backends, '.register / .fetch' do
  let(:stub_backend) { TestHelpers::StubBackend }

  it 'returns the registered backend' do
    described_class.register('argon2id', stub_backend)
    expect(described_class.fetch('argon2id')).to be(stub_backend)
  end

  it 'accepts symbol or string as alg name equivalently' do
    described_class.register(:argon2id, stub_backend)
    expect(described_class.fetch('argon2id')).to be(stub_backend)
  end
end

RSpec.describe Kiosk::Reputation::Backends, '.fetch on an unknown algorithm' do
  let(:stub_backend) { TestHelpers::StubBackend }

  it 'raises KeyError with a descriptive message' do
    described_class.register('argon2id', stub_backend)
    expect { described_class.fetch('cuckoo') }
      .to raise_error(KeyError, /Unknown PoW backend.*cuckoo.*Known.*argon2id/i)
  end

  it 'lists all known algorithms in the error' do
    described_class.register('argon2id', stub_backend)
    described_class.register('cuckoo',   stub_backend)
    expect { described_class.fetch('unknown') }
      .to raise_error(KeyError, /argon2id.*cuckoo/i)
  end
end

RSpec.describe Kiosk::Reputation::Backends, '.known and .reset!' do
  let(:stub_backend) { TestHelpers::StubBackend }

  it 'returns an empty array when nothing is registered' do
    expect(described_class.known).to eq([])
  end

  it 'returns sorted algorithm names' do
    described_class.register('cuckoo',   stub_backend)
    described_class.register('argon2id', stub_backend)
    expect(described_class.known).to eq(%w[argon2id cuckoo])
  end

  it 'clears all registrations' do
    described_class.register('argon2id', stub_backend)
    described_class.reset!
    expect(described_class.known).to be_empty
  end
end

# Challenge.issue signs any alg and params, so a gate asks this before it mints.
# The seam must never invent a refusal that the backend did not state.
RSpec.describe Kiosk::Reputation::Backends, '.valid_params? on a backend that implements it' do
  let(:strict_backend) do
    Class.new do
      def self.valid_params?(params) = params.is_a?(Hash) && params[:n].to_i.positive?
    end
  end

  before { described_class.register('strict', strict_backend) }

  it 'delegates to a backend that implements it — false' do
    expect(described_class.valid_params?('strict', { n: 0 })).to be(false)
  end

  it 'delegates to a backend that implements it — true' do
    expect(described_class.valid_params?('strict', { n: 168 })).to be(true)
  end

  it 'accepts a Symbol alg name, like .fetch' do
    expect(described_class.valid_params?(:strict, { n: 0 })).to be(false)
  end
end

RSpec.describe Kiosk::Reputation::Backends, '.valid_params? with no opinion to delegate to' do
  # StubBackend responds to .verify only.
  it 'answers TRUE for a backend that does not implement it (unconstrained)' do
    described_class.register('argon2id', TestHelpers::StubBackend)
    expect(described_class.valid_params?('argon2id', { anything: 'at all' })).to be(true)
  end

  # .fetch reports an unregistered alg and names the registered ones. A raise
  # here would turn that into a mint-time 500 and lose the message.
  it 'answers TRUE for an UNREGISTERED algorithm rather than raising' do
    expect(described_class.valid_params?('nothing-registered', { n: 168 })).to be(true)
    expect { described_class.fetch('nothing-registered') }.to raise_error(KeyError)
  end
end
