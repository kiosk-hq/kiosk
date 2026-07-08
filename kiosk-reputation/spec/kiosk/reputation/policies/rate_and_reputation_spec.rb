# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::RateAndReputation do
  # The policy is self-contained: it returns an equihash challenge spec
  # `{alg:, params:, count:}` and never touches the Backends registry (the gate
  # resolves the equihash backend at verify time). So no backend stub is needed.

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

  # Proof COUNT demanded for the given factors (nil = free pass).
  def count_for(factor_overrides = {})
    result = policy.challenge_for(identity: nil, verb: :query, factors: factors(factor_overrides))
    result && result[:count]
  end

  # ---------------------------------------------------------------------------
  # nil (serve without challenge)
  # ---------------------------------------------------------------------------
  describe "nil (free pass)" do
    it "returns nil for a proven, low-rate, clean principal" do
      expect(count_for(settled_purchases_count: 5, request_rate_per_min: 10, bad_proof_count: 0)).to be_nil
    end

    it "returns nil when purchases exceed the threshold with zero rate" do
      expect(count_for(settled_purchases_count: 100, request_rate_per_min: 0, bad_proof_count: 0)).to be_nil
    end

    it "challenges all-nil factors (purchases nil == 0 < threshold)" do
      expect(count_for(settled_purchases_count: nil, request_rate_per_min: nil, bad_proof_count: nil)).not_to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Challenge shape: equihash + count
  # ---------------------------------------------------------------------------
  describe "challenge shape" do
    subject(:result) do
      policy.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 0, request_rate_per_min: 5)
      )
    end

    it "issues an :equihash challenge (argon2id is legacy)" do
      expect(result[:alg]).to eq("equihash")
    end

    it "carries equihash (n, k) params" do
      expect(result[:params]).to eq({ n: 192, k: 7 })
    end

    it "carries an integer proof count >= 1" do
      expect(result[:count]).to be_a(Integer)
      expect(result[:count]).to be >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Unproven principal (0 purchases)
  # ---------------------------------------------------------------------------
  describe "unproven principal" do
    it "demands base_count + unproven bonus when rate is low" do
      # base_count(1) + unproven_count_bonus(1) = 2
      expect(count_for(settled_purchases_count: 0, request_rate_per_min: 5)).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # High rate escalation
  # ---------------------------------------------------------------------------
  describe "high request rate" do
    it "challenges a proven principal whose rate exceeds low_rate_threshold" do
      expect(count_for(settled_purchases_count: 5, request_rate_per_min: 20)).not_to be_nil
    end

    it "escalates count as rate increases (proven principal, no bad proofs)" do
      c_at_20  = count_for(settled_purchases_count: 5, request_rate_per_min: 20,  bad_proof_count: 0)
      c_at_100 = count_for(settled_purchases_count: 5, request_rate_per_min: 100, bad_proof_count: 0)
      expect(c_at_100).to be > c_at_20
    end

    it "combines rate escalation with the unproven bonus" do
      # base(1) + rate_excess(ceil((20-10)/10)=1) + unproven(1) = 3
      expect(count_for(settled_purchases_count: 0, request_rate_per_min: 20)).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # bad_proof_count escalation
  # ---------------------------------------------------------------------------
  describe "bad_proof_count escalation" do
    it "challenges even a proven, low-rate principal when bad_proof_count > 0" do
      expect(count_for(settled_purchases_count: 5, request_rate_per_min: 5, bad_proof_count: 1)).not_to be_nil
    end

    it "escalates count as bad_proof_count increases" do
      c1 = count_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 1)
      c2 = count_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 2)
      expect(c2).to be > c1
    end

    it "escalates faster than rate (bad_proof_count_factor(3) > rate_count_step(1))" do
      # unproven base is 2; +3 per bad proof.
      c_bad_proof = count_for(settled_purchases_count: 0, request_rate_per_min: 0, bad_proof_count: 1)
      expect(c_bad_proof - 2).to be >= 3
    end
  end

  # ---------------------------------------------------------------------------
  # count clamping
  # ---------------------------------------------------------------------------
  describe "count clamping" do
    it "caps count at count_max (10) even with extreme inputs" do
      extreme = count_for(settled_purchases_count: 0, request_rate_per_min: 10_000, bad_proof_count: 100)
      expect(extreme).to eq(10)
    end

    it "floors count at count_min (1)" do
      policy_low = described_class.new(base_count: 0, unproven_count_bonus: 0, count_min: 1)
      result     = policy_low.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 0, request_rate_per_min: 0)
      )
      expect(result[:count]).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Custom thresholds
  # ---------------------------------------------------------------------------
  describe "custom constructor params" do
    it "respects a custom proven_purchases_threshold" do
      strict = described_class.new(proven_purchases_threshold: 100)
      result = strict.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 5, request_rate_per_min: 5, bad_proof_count: 0)
      )
      expect(result).not_to be_nil
    end

    it "respects a custom low_rate_threshold" do
      lenient = described_class.new(low_rate_threshold: 200)
      expect(
        lenient.challenge_for(
          identity: nil, verb: :query,
          factors: factors(settled_purchases_count: 5, request_rate_per_min: 100, bad_proof_count: 0)
        )
      ).to be_nil
    end

    it "respects custom equihash (n, k) params" do
      tuned  = described_class.new(equihash_n: 200, equihash_k: 9)
      result = tuned.challenge_for(
        identity: nil, verb: :query,
        factors: factors(settled_purchases_count: 0, request_rate_per_min: 5)
      )
      expect(result[:params]).to eq({ n: 200, k: 9 })
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
