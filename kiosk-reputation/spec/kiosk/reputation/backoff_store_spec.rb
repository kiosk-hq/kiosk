# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::BackoffStore, '#consume' do
  subject(:store) { described_class.new }

  it 'returns false (no grant available)' do
    expect(store.consume('k')).to be(false)
  end

  it 'returns false repeatedly (never goes negative)' do
    3.times { expect(store.consume('k')).to be(false) }
  end

  it 'consuming one key does not affect another' do
    store.grant('a', 1)
    expect(store.consume('b')).to be(false)
    expect(store.consume('a')).to be(true)
  end
end

RSpec.describe Kiosk::Reputation::BackoffStore, '#grant' do
  subject(:store) { described_class.new }

  it 'returns true exactly n times, then false' do
    store.grant('k', 3)
    expect(Array.new(4) { store.consume('k') }).to eq([true, true, true, false])
  end

  it 'decrements to zero and stops (a 4th consume after grant(3) is false)' do
    store.grant('k', 3)
    3.times { store.consume('k') }
    expect(store.consume('k')).to be(false)
  end

  it 'a second grant sets the count (does not add to remaining)' do
    store.grant('k', 3)
    store.consume('k')
    store.grant('k', 3)
    expect(Array.new(4) { store.consume('k') }).to eq([true, true, true, false])
  end

  it 'grants nothing (consume is immediately false)' do
    store.grant('k', 0)
    expect(store.consume('k')).to be(false)
  end
end
