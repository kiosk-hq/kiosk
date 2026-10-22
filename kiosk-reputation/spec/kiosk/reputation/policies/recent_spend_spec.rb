# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RecentSpend do
  subject(:policy) { described_class.new(within: 7 * 86_400, cap: 100) }

  let(:proof) { { alg: 'equihash', params: { n: 168, k: 7 }, count: 1 } }

  def toll(cents, calls)
    factors = Kiosk::Reputation::Factors.empty.with(settled_purchases_cents: cents, calls_since_proof: calls)
    policy.challenge_for(identity: nil, verb: :query, factors:)
  end

  # The first call that pays, counting from the last proof, among the next 200.
  def first_tolled_call(cents) = (1..200).find { toll(cents, it) }

  it 'tolls every 10th call of a customer with no recent spend' do
    expect([toll(nil, 9), toll(nil, 10)]).to eq([nil, proof])
  end

  it 'stretches the interval linearly with spend: 14, 20 and 40 calls at a quarter, half and three quarters of the cap' do
    expect([0, 25_00, 50_00, 75_00].map { first_tolled_call(it) }).to eq([10, 14, 20, 40])
  end

  it 'tolls no call of a customer who spent the cap or more' do
    expect([100_00, 150_00].map { first_tolled_call(it) }).to eq([nil, nil])
  end

  it 'reads the cap in whole currency units and the spend in cents' do
    expect([0, 25_00, 50_00, 75_00, 100_00, 150_00].map { policy.interval(it) }).to eq([10, 14, 20, 40, nil, nil])
  end

  it 'keeps tolling every call past the interval until a proof is paid' do
    expect([toll(50_00, 21), toll(50_00, 35)]).to eq([proof, proof])
  end

  it 'tolls every call of a caller that the engine does not count' do
    expect([toll(0, nil), toll(99_00, nil), toll(100_00, nil)]).to eq([proof, proof, nil])
  end

  it 'publishes its window for the engine to count spend in' do
    expect(policy.within).to eq(7 * 86_400)
  end
end
