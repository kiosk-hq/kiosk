# frozen_string_literal: true

RSpec.describe Kiosk::Reputation::Challenge do
  # Inject deterministic values so tests don't depend on random state.
  let(:secret)      { "test-hmac-secret" }
  let(:fingerprint) { "fp:sha256:abc123" }
  let(:salt)        { "A" * 16 }           # 16 raw bytes (ASCII)
  let(:id)          { "challenge-uuid-001" }
  let(:now)         { 1_750_000_000 }
  let(:ttl)         { 300 }
  let(:params)      { { m: 65_536, t: 1, p: 1, d: 6 } }
  let(:alg)         { "argon2id" }

  let(:challenge) do
    described_class.issue(
      alg: alg, params: params,
      request_fingerprint: fingerprint,
      secret: secret, ttl: ttl,
      now: now, salt: salt, id: id
    )
  end

  before do
    Kiosk::Reputation::Backends.register("argon2id", TestHelpers::StubBackend)
  end

  # ---------------------------------------------------------------------------
  # .issue
  # ---------------------------------------------------------------------------
  describe ".issue" do
    it "returns a hash with all required wire fields" do
      expect(challenge).to include(:id, :alg, :params, :salt, :exp, :sig)
    end

    it "sets exp = now + ttl" do
      expect(challenge[:exp]).to eq(now + ttl)
    end

    it "base64-encodes the raw salt" do
      expect(challenge[:salt]).to eq(Base64.strict_encode64(salt))
    end

    it "stores the injected id" do
      expect(challenge[:id]).to eq(id)
    end

    it "produces a non-empty sig" do
      expect(challenge[:sig]).not_to be_empty
    end

    it "uses SecureRandom defaults when salt/id are not injected" do
      c1 = described_class.issue(
        alg: alg, params: params,
        request_fingerprint: fingerprint,
        secret: secret, ttl: ttl, now: now
      )
      c2 = described_class.issue(
        alg: alg, params: params,
        request_fingerprint: fingerprint,
        secret: secret, ttl: ttl, now: now
      )
      expect(c1[:id]).not_to eq(c2[:id])
      expect(c1[:salt]).not_to eq(c2[:salt])
    end
  end

  # ---------------------------------------------------------------------------
  # .verify — happy path
  # ---------------------------------------------------------------------------
  describe ".verify — round-trip" do
    it "returns :ok for a correct nonce and matching fingerprint/secret" do
      result = described_class.verify(
        challenge: challenge,
        nonce: "good",
        request_fingerprint: fingerprint,
        secret: secret,
        now: now + 1
      )
      expect(result).to eq(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # .verify — :bad_sig cases (cheap check, step 1)
  # ---------------------------------------------------------------------------
  describe ".verify — :bad_sig" do
    def verify_with(overrides = {})
      c = overrides.key?(:challenge) ? overrides[:challenge] : challenge.dup
      described_class.verify(
        challenge: c,
        nonce: "good",
        request_fingerprint: overrides.fetch(:request_fingerprint, fingerprint),
        secret: overrides.fetch(:secret, secret),
        now: overrides.fetch(:now, now + 1)
      )
    end

    it "returns :bad_sig when params are tampered" do
      tampered = challenge.merge(params: { m: 65_536, t: 1, p: 1, d: 99 })
      expect(verify_with(challenge: tampered)).to eq(:bad_sig)
    end

    it "returns :bad_sig when salt is tampered" do
      tampered = challenge.merge(salt: Base64.strict_encode64("X" * 16))
      expect(verify_with(challenge: tampered)).to eq(:bad_sig)
    end

    it "returns :bad_sig when exp is tampered" do
      tampered = challenge.merge(exp: now + ttl + 9999)
      expect(verify_with(challenge: tampered)).to eq(:bad_sig)
    end

    it "returns :bad_sig when request_fingerprint at verify differs from issue" do
      expect(verify_with(request_fingerprint: "fp:different")).to eq(:bad_sig)
    end

    it "returns :bad_sig when a wrong secret is used at verify" do
      expect(verify_with(secret: "wrong-secret")).to eq(:bad_sig)
    end

    it "returns :bad_sig when the sig field itself is corrupted" do
      tampered = challenge.merge(sig: "deadbeef" * 8)
      expect(verify_with(challenge: tampered)).to eq(:bad_sig)
    end

    context "anti-DoS ordering — backend is NOT called on :bad_sig" do
      it "does not invoke the backend when sig is wrong (uses spy backend)" do
        Kiosk::Reputation::Backends.reset!
        Kiosk::Reputation::Backends.register("argon2id", TestHelpers::SpyRaisingBackend)

        tampered = challenge.merge(sig: "badbad" * 10 + "ab")
        # If the backend were called the SpyRaisingBackend would raise.
        expect do
          described_class.verify(
            challenge: tampered,
            nonce: "good",
            request_fingerprint: fingerprint,
            secret: secret,
            now: now + 1
          )
        end.not_to raise_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .verify — :expired (cheap check, step 2)
  # ---------------------------------------------------------------------------
  describe ".verify — :expired" do
    it "returns :expired when now >= exp" do
      result = described_class.verify(
        challenge: challenge,
        nonce: "good",
        request_fingerprint: fingerprint,
        secret: secret,
        now: now + ttl + 1  # one second past exp
      )
      expect(result).to eq(:expired)
    end

    context "anti-DoS ordering — backend is NOT called on :expired" do
      it "does not invoke the backend for an expired challenge (uses spy backend)" do
        Kiosk::Reputation::Backends.reset!
        Kiosk::Reputation::Backends.register("argon2id", TestHelpers::SpyRaisingBackend)

        # Re-issue with the spy backend now registered.
        c = described_class.issue(
          alg: alg, params: params,
          request_fingerprint: fingerprint,
          secret: secret, ttl: ttl,
          now: now, salt: salt, id: id
        )

        # If the backend were called the SpyRaisingBackend would raise.
        expect do
          described_class.verify(
            challenge: c,
            nonce: "good",
            request_fingerprint: fingerprint,
            secret: secret,
            now: now + ttl + 1
          )
        end.not_to raise_error
      end

      it "returns :expired (not any other symbol) for the expired spy scenario" do
        Kiosk::Reputation::Backends.reset!
        Kiosk::Reputation::Backends.register("argon2id", TestHelpers::SpyRaisingBackend)

        c = described_class.issue(
          alg: alg, params: params,
          request_fingerprint: fingerprint,
          secret: secret, ttl: ttl,
          now: now, salt: salt, id: id
        )

        result = described_class.verify(
          challenge: c, nonce: "good",
          request_fingerprint: fingerprint,
          secret: secret,
          now: now + ttl + 1
        )
        expect(result).to eq(:expired)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .verify — :bad_proof (expensive check, step 3)
  # ---------------------------------------------------------------------------
  describe ".verify — :bad_proof" do
    it "returns :bad_proof when the nonce is wrong but the challenge is valid" do
      result = described_class.verify(
        challenge: challenge,
        nonce: "bad",
        request_fingerprint: fingerprint,
        secret: secret,
        now: now + 1
      )
      expect(result).to eq(:bad_proof)
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical string stability
  # ---------------------------------------------------------------------------
  describe "canonical string is param-key-order-independent" do
    it "produces the same sig regardless of params hash key insertion order" do
      c1 = described_class.issue(
        alg: alg, params: { m: 65_536, t: 1, p: 1, d: 6 },
        request_fingerprint: fingerprint, secret: secret,
        ttl: ttl, now: now, salt: salt, id: id
      )
      c2 = described_class.issue(
        alg: alg, params: { d: 6, p: 1, t: 1, m: 65_536 },
        request_fingerprint: fingerprint, secret: secret,
        ttl: ttl, now: now, salt: salt, id: id
      )
      expect(c1[:sig]).to eq(c2[:sig])
    end
  end
end
