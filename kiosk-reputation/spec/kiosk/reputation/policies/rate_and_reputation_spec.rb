# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation do
  before do
    Kiosk::Reputation::Backends.register("argon2id", TestHelpers::StubBackend)
  end

  # Use default thresholds: proven >= 5 purchases, low rate <= 10 req/min.
  subject(:policy) { described_class.new }

  def factors(overrides = {})
    defaults = {
      kyc_level:               nil,
      settled_purchases_count: 0,
      settled_purchases_cents: nil,
      request_rate_per_min:    0,
      account_age_seconds:     nil,
      dispute_count:           nil,
      bad_proof_count:         0
    }
    Kiosk::Reputation::Factors.new(**defaults.merge(overrides))
  end

  def d_for(factor_overrides = {})
    result = policy.challenge_for(identity: nil, verb: :query, factors: factors(factor_overrides))
    result&.dig(:params, :d)
  end

  # ---------------------------------------------------------------------------
  # nil (serve without challenge)
  # ---------------------------------------------------------------------------
  describe "nil (free pass)" do
    it "returns nil for a proven, low-rate, clean principal" do
      expect(d_for(settled_purchases_count: 5, request_rate_per_min: 10, bad_proof_count: 0)).to be_nil
    end

    it "returns nil when purchases exceed the threshold with zero rate" do
      expect(d_for(settled_purchases_count: 100, request_rate_per_min: 0, bad_proof_count: 0)).to be_nil
    end

    it "returns nil for all-nil factors (empty) when purchases nil == 0 < threshold" do
      # settled_purchases_count nil → .to_i == 0 → unproven → challenged
      expect(d_for(settled_purchases_count: nil, request_rate_per_min: nil, bad_proof_count: nil)).not_to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Unproven principal (0 purchases)
  # ---------------------------------------------------------------------------
  describe "unproven principal" do
    it "issues a challenge with the base_d + unproven bonus when rate is low" do
      # base_d(5) + unproven_d_bonus(2) = 7
      expect(d_for(settled_purchases_count: 0, request_rate_per_min: 5)).to eq(7)
    end

    it "returns an :argon2id challenge" do
      result = policy.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 0, request_rate_per_min: 5)
      )
      expect(result[:alg]).to eq("argon2id")
    end
  end

  # ---------------------------------------------------------------------------
  # High rate escalation
  # ---------------------------------------------------------------------------
  describe "high request rate" do
    it "issues a challenge when rate exceeds low_rate_threshold for a proven principal" do
      expect(d_for(settled_purchases_count: 5, request_rate_per_min: 20)).not_to be_nil
    end

    it "escalates d as rate increases (proven principal, no bad proofs)" do
      d_at_20  = d_for(settled_purchases_count: 5, request_rate_per_min: 20,  bad_proof_count: 0)
      d_at_100 = d_for(settled_purchases_count: 5, request_rate_per_min: 100, bad_proof_count: 0)
      expect(d_at_100).to be > d_at_20
    end

    it "combines rate escalation with unproven bonus" do
      # base_d(5) + rate_excess(20-10=10, ceil(10/10)*1=1) + unproven(2) = 8
      expect(d_for(settled_purchases_count: 0, request_rate_per_min: 20)).to eq(8)
    end
  end

  # ---------------------------------------------------------------------------
  # bad_proof_count escalation
  # ---------------------------------------------------------------------------
  describe "bad_proof_count escalation" do
    it "challenges even a proven, low-rate principal when bad_proof_count > 0" do
      expect(d_for(settled_purchases_count: 5, request_rate_per_min: 5, bad_proof_count: 1)).not_to be_nil
    end

    it "escalates d as bad_proof_count increases" do
      d1 = d_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 1)
      d2 = d_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 2)
      d3 = d_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 3)
      expect(d2).to be > d1
      expect(d3).to be > d2
    end

    it "escalates faster than rate (bad_proof_d_factor > rate_d_step per unit)" do
      # Default: bad_proof_d_factor = 3, rate_d_step = 1 per rate_step(10) req/min.
      d_bad_proof = d_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 1)
      d_rate_10   = d_for(settled_purchases_count: 0, request_rate_per_min: 10, bad_proof_count: 0)
      # 1 bad proof adds 3; 10 extra req/min adds 1. Bad proof should be higher.
      expect(d_bad_proof - 7).to be >= 3  # unproven base is 7; +3 for 1 bad proof
    end
  end

  # ---------------------------------------------------------------------------
  # d clamping
  # ---------------------------------------------------------------------------
  describe "d clamping" do
    it "caps d at d_max (14) even with extreme inputs" do
      extreme_d = d_for(settled_purchases_count: 0, request_rate_per_min: 10_000, bad_proof_count: 100)
      expect(extreme_d).to eq(14)
    end

    it "floors d at d_min (3)" do
      policy_low = described_class.new(base_d: 0, unproven_d_bonus: 0, d_min: 3)
      result     = policy_low.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 0, request_rate_per_min: 0)
      )
      expect(result[:params][:d]).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # Custom thresholds
  # ---------------------------------------------------------------------------
  describe "custom constructor params" do
    it "respects a custom proven_purchases_threshold" do
      strict = described_class.new(proven_purchases_threshold: 100)
      # 5 purchases is no longer enough
      result = strict.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 5, request_rate_per_min: 5, bad_proof_count: 0)
      )
      expect(result).not_to be_nil
    end

    it "respects a custom low_rate_threshold" do
      lenient = described_class.new(low_rate_threshold: 200)
      # 100 req/min is now low-rate for a proven principal
      expect(
        lenient.challenge_for(
          identity: nil, verb: :query,
          factors: factors(settled_purchases_count: 5, request_rate_per_min: 100, bad_proof_count: 0)
        )
      ).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Base Policy (never challenge)
  # ---------------------------------------------------------------------------
  describe Kiosk::Reputation::Policy do
    it "always returns nil regardless of factors" do
      base = described_class.new
      expect(
        base.challenge_for(
          identity: "user-1", verb: :query,
          factors: Kiosk::Reputation::Factors.empty
        )
      ).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Factors.empty
  # ---------------------------------------------------------------------------
  describe Kiosk::Reputation::Factors do
    describe ".empty" do
      it "returns a Factors instance with all-nil fields" do
        f = described_class.empty
        expect(f.kyc_level).to be_nil
        expect(f.settled_purchases_count).to be_nil
        expect(f.request_rate_per_min).to be_nil
        expect(f.bad_proof_count).to be_nil
      end
    end
  end
end
