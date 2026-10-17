# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RecentSpend do
  subject(:policy) { described_class.new(trusted_at: 100_00, within: 7 * 86_400, count: 4) }

  def toll(cents)
    factors = Kiosk::Reputation::Factors.empty.with(settled_purchases_cents: cents)
    policy.challenge_for(identity: nil, verb: :query, factors:)
  end

  it 'asks the full count of a customer with no recent spend' do
    expect(toll(nil)).to eq(alg: 'equihash', params: { n: 168, k: 7 }, count: 4)
  end

  it 'asks nothing of a customer at or above trusted_at' do
    expect([toll(100_00), toll(250_00)]).to eq([nil, nil])
  end

  it 'lowers the count logarithmically with recent spend' do
    expect([toll(10), toll(100), toll(10_00)].map { it&.fetch(:count) }).to eq([3, 2, 1])
  end

  it 'publishes its window for the engine to count spend in' do
    expect(policy.within).to eq(7 * 86_400)
  end
end
