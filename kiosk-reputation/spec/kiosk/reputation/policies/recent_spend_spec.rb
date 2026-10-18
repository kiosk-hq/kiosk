# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RecentSpend do
  subject(:policy) { described_class.new(within: 7 * 86_400, cap: 100) }

  def token(jti) = Struct.new(:claims).new({ jti: jti })
  def tokens(count) = Array.new(count) { |i| token("t-#{i}") }

  def toll(cents, identity)
    factors = Kiosk::Reputation::Factors.empty.with(settled_purchases_cents: cents)
    policy.challenge_for(identity: identity, verb: :query, factors:)
  end

  def tolled_share(cents, count: 4_000) = tokens(count).count { toll(cents, it) }.fdiv(count)

  it 'tolls every session of a customer with no recent spend' do
    expect(tokens(1_000).map { toll(nil, it) }.uniq).to eq([{ alg: 'equihash', params: { n: 168, k: 7 }, count: 1 }])
  end

  it 'tolls no session of a customer who spent the cap or more' do
    expect(tokens(1_000).flat_map { [toll(100_00, it), toll(250_00, it)] }.uniq).to eq([nil])
  end

  it 'tolls a session with a chance that falls linearly from 1 to 0 as spend reaches the cap' do
    expect([tolled_share(25_00), tolled_share(50_00), tolled_share(75_00)]).to match([be_within(0.02).of(0.75), be_within(0.02).of(0.5), be_within(0.02).of(0.25)])
  end

  it 'draws once per access token, so each call made with one token meets the same outcome' do
    expect(tokens(1_000).map { |t| Array.new(3) { toll(25_00, t) }.uniq.size }.uniq).to eq([1])
  end

  it 'reads the cap in whole currency units and the spend in cents' do
    expect([0, 50_00, 100_00, 150_00].map { policy.chance(it) }).to eq([1, 0.5, 0, 0])
  end

  it 'publishes its window for the engine to count spend in' do
    expect(policy.within).to eq(7 * 86_400)
  end
end
