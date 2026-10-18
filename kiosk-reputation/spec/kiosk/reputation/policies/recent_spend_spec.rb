# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RecentSpend do
  # A random source that always draws `draw`, so each example decides the toll.
  def drawing(draw) = Struct.new(:draw) { def rand = draw }.new(draw)

  def toll(cents, draw:)
    policy = described_class.new(within: 7 * 86_400, cap: 100, random: drawing(draw))
    factors = Kiosk::Reputation::Factors.empty.with(settled_purchases_cents: cents)
    policy.challenge_for(identity: nil, verb: :query, factors:)
  end

  it 'tolls every session of a customer with no recent spend' do
    expect(toll(nil, draw: 0.999)).to eq(alg: 'equihash', params: { n: 168, k: 7 }, count: 1)
  end

  it 'tolls no session of a customer who spent the cap or more' do
    expect([toll(100_00, draw: 0.0), toll(250_00, draw: 0.0)]).to eq([nil, nil])
  end

  it 'tolls a session with a chance that falls linearly from 1 to 0 as spend reaches the cap' do
    expect([toll(25_00, draw: 0.749), toll(25_00, draw: 0.75)]).to eq([toll(nil, draw: 0.0), nil])
  end

  it 'reads the cap in whole currency units and the spend in cents' do
    policy = described_class.new(within: 7 * 86_400, cap: 100)
    expect([0, 50_00, 100_00, 150_00].map { policy.chance(it) }).to eq([1, 0.5, 0, 0])
  end

  it 'publishes its window for the engine to count spend in' do
    expect(described_class.new(within: 7 * 86_400, cap: 100).within).to eq(7 * 86_400)
  end
end
