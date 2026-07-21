# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Policies::Backoff do
  let(:base) { { alg: "equihash", params: { n: 96, k: 5 }, count: 1 } }

  subject(:policy) { described_class.new(count: 3, base: base) }

  # An opaque string identity and a Kiosk::Identity-shaped double both exercise
  # identity_key. We avoid depending on kiosk-core here (this gem doesn't), so
  # the "identity object" is a lightweight struct with the same duck type.
  IdentityDouble = Struct.new(:agent_id, :user_id) do
    def to_s = "IdentityDouble"
  end

  # ---------------------------------------------------------------------------
  # consume-before-grant → challenges
  # ---------------------------------------------------------------------------
  describe "with no grant yet (consume before grant)" do
    it "challenges (returns a dup of base) on the very first request" do
      spec = policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)
      expect(spec).to eq(base)
    end

    it "keeps challenging on every request while ungranted" do
      3.times do
        expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to eq(base)
      end
    end

    it "returns a distinct dup each time (not the frozen internal base)" do
      spec = policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)
      expect(spec).not_to be_frozen
      expect { spec[:count] = 9 }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # grant then consume N times → nil ×N then challenge again
  # ---------------------------------------------------------------------------
  describe "after on_proof_verified (a solve grants count free calls)" do
    it "serves the next `count` requests without a challenge, then re-challenges" do
      policy.on_proof_verified(identity: "agent-1")

      # count == 3 → next 3 requests are free (nil), 4th is challenged.
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to eq(base)
    end

    it "grants are per-identity (agent-2's solve does not free agent-1)" do
      policy.on_proof_verified(identity: "agent-2")
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to eq(base)
      expect(policy.challenge_for(identity: "agent-2", verb: :query, factors: nil)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # on_proof_verified resets
  # ---------------------------------------------------------------------------
  describe "on_proof_verified resets the remaining grants" do
    it "a fresh solve mid-burst resets the count back to `count`" do
      policy.on_proof_verified(identity: "agent-1")
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil # 2 left
      policy.on_proof_verified(identity: "agent-1")                                            # reset to 3
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil # 2
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil # 1
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil # 0
      expect(policy.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to eq(base)
    end
  end

  # ---------------------------------------------------------------------------
  # identity_key resolution
  # ---------------------------------------------------------------------------
  describe "identity_key" do
    it "keys a Kiosk::Identity-shaped object by agent_id when present" do
      id_a = IdentityDouble.new("agent-x", "user-1")
      policy.on_proof_verified(identity: id_a)
      # A different object with the SAME agent_id shares the grant.
      id_a_again = IdentityDouble.new("agent-x", "user-1")
      expect(policy.challenge_for(identity: id_a_again, verb: :query, factors: nil)).to be_nil
    end

    it "falls back to user_id when agent_id is nil" do
      id = IdentityDouble.new(nil, "user-42")
      policy.on_proof_verified(identity: id)
      expect(policy.challenge_for(identity: IdentityDouble.new(nil, "user-42"), verb: :query, factors: nil)).to be_nil
      # A different user_id is not freed.
      expect(policy.challenge_for(identity: IdentityDouble.new(nil, "user-99"), verb: :query, factors: nil)).to eq(base)
    end

    it "distinguishes two agents of the same user by agent_id" do
      policy.on_proof_verified(identity: IdentityDouble.new("agent-A", "user-1"))
      # agent-B of the same user is still challenged.
      expect(policy.challenge_for(identity: IdentityDouble.new("agent-B", "user-1"), verb: :query, factors: nil)).to eq(base)
    end

    it "keys a plain string identity by its own value" do
      policy.on_proof_verified(identity: "opaque-token")
      expect(policy.challenge_for(identity: "opaque-token", verb: :query, factors: nil)).to be_nil
      expect(policy.challenge_for(identity: "other-token", verb: :query, factors: nil)).to eq(base)
    end
  end

  # ---------------------------------------------------------------------------
  # pluggable store
  # ---------------------------------------------------------------------------
  describe "pluggable store" do
    it "delegates consume/grant to an injected store" do
      shared = Kiosk::Reputation::BackoffStore.new
      p1 = described_class.new(count: 2, base: base, store: shared)
      p2 = described_class.new(count: 2, base: base, store: shared)

      # A solve recorded through p1 is visible to p2 (shared store).
      p1.on_proof_verified(identity: "agent-1")
      expect(p2.challenge_for(identity: "agent-1", verb: :query, factors: nil)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # constructor validation
  # ---------------------------------------------------------------------------
  describe "constructor validation" do
    it "rejects count < 1" do
      expect { described_class.new(count: 0, base: base) }.to raise_error(ArgumentError, /count must be >= 1/)
    end

    it "coerces a numeric-string count" do
      p = described_class.new(count: "2", base: base)
      p.on_proof_verified(identity: "a")
      expect(p.challenge_for(identity: "a", verb: :query, factors: nil)).to be_nil
      expect(p.challenge_for(identity: "a", verb: :query, factors: nil)).to be_nil
      expect(p.challenge_for(identity: "a", verb: :query, factors: nil)).to eq(base)
    end

    it "rejects a base without :alg" do
      expect { described_class.new(count: 1, base: { params: { n: 96, k: 5 } }) }
        .to raise_error(ArgumentError, /base must be a challenge spec/)
    end

    it "rejects a base without :params" do
      expect { described_class.new(count: 1, base: { alg: "equihash" }) }
        .to raise_error(ArgumentError, /base must be a challenge spec/)
    end

    it "rejects a non-Hash base" do
      expect { described_class.new(count: 1, base: "nope") }
        .to raise_error(ArgumentError, /base must be a challenge spec/)
    end
  end

  # ---------------------------------------------------------------------------
  # is a Policy
  # ---------------------------------------------------------------------------
  it "is a Kiosk::Reputation::Policy" do
    expect(policy).to be_a(Kiosk::Reputation::Policy)
  end
end
