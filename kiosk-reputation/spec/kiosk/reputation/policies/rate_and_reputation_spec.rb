# frozen_string_literal: true

# The policy returns an equihash challenge spec `{alg:, params:, count:}` and
# never reads the Backends registry, so no backend stub is needed. The default
# thresholds: proven at 5 or more purchases, low rate at 10 req/min or less.
module RateAndReputationCalls
  FACTOR_DEFAULTS = {
    kyc_level: nil, settled_purchases_count: 0, settled_purchases_cents: nil, request_rate_per_min: 0,
    account_age_seconds: nil, dispute_count: nil, bad_proof_count: 0
  }.freeze

  def challenge(asked = policy, **factor_overrides)
    factors = Kiosk::Reputation::Factors.new(**FACTOR_DEFAULTS, **factor_overrides)
    asked.challenge_for(identity: nil, verb: :query, factors:)
  end

  # Proof COUNT demanded for the given factors (nil = free pass).
  def count_for(**factor_overrides)
    challenge(**factor_overrides)&.fetch(:count)
  end
end

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation, 'free pass and challenge shape' do
  include RateAndReputationCalls

  subject(:policy) { described_class.new }

  it 'returns nil for a proven, low-rate, clean principal' do
    expect(count_for(settled_purchases_count: 5, request_rate_per_min: 10, bad_proof_count: 0)).to be_nil
  end

  it 'returns nil when purchases exceed the threshold with zero rate' do
    expect(count_for(settled_purchases_count: 100, request_rate_per_min: 0, bad_proof_count: 0)).to be_nil
  end

  it 'challenges all-nil factors (purchases nil == 0 < threshold)' do
    expect(count_for(settled_purchases_count: nil, request_rate_per_min: nil, bad_proof_count: nil)).not_to be_nil
  end

  it 'issues an :equihash challenge (argon2id is legacy)' do
    expect(challenge(request_rate_per_min: 5)[:alg]).to eq('equihash')
  end

  it 'carries equihash (n, k) params' do
    expect(challenge(request_rate_per_min: 5)[:params]).to eq({ n: 168, k: 7 })
  end

  it 'carries an integer proof count >= 1' do
    expect(count_for(request_rate_per_min: 5)).to be_a(Integer)
    expect(count_for(request_rate_per_min: 5)).to be >= 1
  end
end

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation, 'unproven principal and request rate' do
  include RateAndReputationCalls

  subject(:policy) { described_class.new }

  it 'demands base_count + unproven bonus when rate is low' do
    expect(count_for(settled_purchases_count: 0, request_rate_per_min: 5)).to eq(2)
  end

  # 3 purchases is below the proven threshold but not zero: no unproven bonus.
  it 'adds the unproven bonus ONLY at zero purchases, not merely below the proven threshold' do
    expect(count_for(settled_purchases_count: 3, request_rate_per_min: 5)).to eq(1)
  end

  it 'challenges a proven principal whose rate exceeds low_rate_threshold' do
    expect(count_for(settled_purchases_count: 5, request_rate_per_min: 20)).not_to be_nil
  end

  it 'escalates count as rate increases (proven principal, no bad proofs)' do
    expect(count_for(settled_purchases_count: 5, request_rate_per_min: 100))
      .to be > count_for(settled_purchases_count: 5, request_rate_per_min: 20)
  end

  # base(1) + rate excess(ceil((20 - 10) / 10) = 1) + unproven(1) = 3
  it 'combines rate escalation with the unproven bonus' do
    expect(count_for(settled_purchases_count: 0, request_rate_per_min: 20)).to eq(3)
  end
end

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation, 'bad proofs and clamping' do
  include RateAndReputationCalls

  subject(:policy) { described_class.new }

  it 'challenges even a proven, low-rate principal when bad_proof_count > 0' do
    expect(count_for(settled_purchases_count: 5, request_rate_per_min: 5, bad_proof_count: 1)).not_to be_nil
  end

  it 'escalates count as bad_proof_count increases' do
    expect(count_for(bad_proof_count: 2)).to be > count_for(bad_proof_count: 1)
  end

  # The unproven base is 2; each bad proof adds 3.
  it 'escalates faster than rate (bad_proof_count_factor(3) > rate_count_step(1))' do
    expect(count_for(bad_proof_count: 1) - 2).to be >= 3
  end

  it 'caps count at count_max (10) even with extreme inputs' do
    expect(count_for(request_rate_per_min: 10_000, bad_proof_count: 100)).to eq(10)
  end

  it 'floors count at count_min (1)' do
    floor = described_class.new(base_count: 0, unproven_count_bonus: 0, count_min: 1)
    expect(challenge(floor)[:count]).to eq(1)
  end
end

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation, 'custom constructor params' do
  include RateAndReputationCalls

  it 'respects a custom proven_purchases_threshold' do
    strict = described_class.new(proven_purchases_threshold: 100)
    expect(challenge(strict, settled_purchases_count: 5, request_rate_per_min: 5)).not_to be_nil
  end

  it 'respects a custom low_rate_threshold' do
    lenient = described_class.new(low_rate_threshold: 200)
    expect(challenge(lenient, settled_purchases_count: 5, request_rate_per_min: 100)).to be_nil
  end

  it 'respects custom equihash (n, k) params' do
    tuned = described_class.new(equihash_n: 200, equihash_k: 9)
    expect(challenge(tuned, request_rate_per_min: 5)[:params]).to eq({ n: 200, k: 9 })
  end
end

RSpec.describe Kiosk::Reputation::Policy do
  it 'always returns nil regardless of factors' do
    expect(described_class.new.challenge_for(identity: 'user-1', verb: :query, factors: Kiosk::Reputation::Factors.empty))
      .to be_nil
  end
end

RSpec.describe Kiosk::Reputation::Factors, '.empty' do
  it 'returns a Factors instance with all-nil fields' do
    factors = described_class.empty
    expect(factors.kyc_level).to be_nil
    expect(factors.settled_purchases_count).to be_nil
    expect(factors.request_rate_per_min).to be_nil
    expect(factors.bad_proof_count).to be_nil
  end
end
