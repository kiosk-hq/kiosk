# frozen_string_literal: true

RSpec.describe Kiosk::Server::AuthChallengeStore do
  subject(:store) { described_class.new }

  let(:pem)   { "-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----" }
  let(:far)   { Time.now.to_i + 300 }

  it "consumes a live, matching challenge exactly once (single-use)" do
    store.put(pem, "nonce-1", far)
    expect(store.take(pem, "nonce-1")).to be(true)
    # Replay of the same nonce is rejected — it was burned.
    expect(store.take(pem, "nonce-1")).to be(false)
  end

  it "rejects a non-matching nonce without consuming the live one" do
    store.put(pem, "nonce-1", far)
    expect(store.take(pem, "wrong")).to be(false)
    # The real challenge still stands.
    expect(store.take(pem, "nonce-1")).to be(true)
  end

  it "rejects an expired challenge" do
    store.put(pem, "nonce-1", Time.now.to_i - 1)
    expect(store.take(pem, "nonce-1")).to be(false)
  end

  it "keeps only the most recently issued challenge per key" do
    store.put(pem, "old", far)
    store.put(pem, "new", far)
    expect(store.take(pem, "old")).to be(false)
    expect(store.take(pem, "new")).to be(true)
  end

  it "returns false for a key that never had a challenge" do
    expect(store.take(pem, "whatever")).to be(false)
  end

  it "prunes expired entries" do
    store.put(pem, "nonce-1", Time.now.to_i - 1)
    store.prune!
    # Even the correct nonce is gone after pruning.
    expect(store.take(pem, "nonce-1")).to be(false)
  end

  # GET /auth/challenge is unauthenticated, so an attacker can flood
  # #put with arbitrarily many DISTINCT public keys. Because #put prunes
  # expired entries on the way in, an all-expired flood cannot accumulate
  # unboundedly — the store does not retain every key seen. (Before the fix,
  # expired entries only cleared on a later #take, which never runs for keys
  # that never register.)
  it "does not accumulate expired distinct-key challenges (bounded growth)" do
    stale = Time.now.to_i - 1
    1_000.times { |i| store.put("key-#{i}", "nonce-#{i}", stale) }

    live = Time.now.to_i + 300
    store.put("live-key", "live-nonce", live)

    # Every prior stale entry was dropped: only the live one remains.
    expect(store_size(store)).to eq(1)
    expect(store.take("live-key", "live-nonce")).to be(true)
  end

  # K-548: prune! only drops EXPIRED entries. GET /auth/challenge is
  # unauthenticated and un-rate-limited, so a distinct-key flood of LIVE
  # (unexpired) challenges would still accumulate rate×TTL entries before any
  # expiry. A hard size cap bounds the store even within the TTL window: at
  # capacity, the oldest live entry is evicted.
  describe "size cap (bounded even within the TTL window)" do
    let(:live) { Time.now.to_i + 300 }

    it "never grows past max_entries when flooded with live distinct keys" do
      capped = described_class.new(max_entries: 10)
      100.times { |i| capped.put("key-#{i}", "nonce-#{i}", live) }
      expect(store_size(capped)).to eq(10)
    end

    it "evicts the OLDEST live entry, keeping the newest" do
      capped = described_class.new(max_entries: 3)
      capped.put("k1", "n1", live)
      capped.put("k2", "n2", live)
      capped.put("k3", "n3", live)
      capped.put("k4", "n4", live) # at capacity → evicts k1 (oldest)

      expect(capped.take("k1", "n1")).to be(false) # evicted
      expect(capped.take("k4", "n4")).to be(true)  # newest survives
    end

    it "re-issuing a key refreshes its position (not evicted as stale-oldest)" do
      capped = described_class.new(max_entries: 3)
      capped.put("k1", "n1", live)
      capped.put("k2", "n2", live)
      capped.put("k1", "n1b", live) # re-issue k1 → moves to newest
      capped.put("k3", "n3", live)
      capped.put("k4", "n4", live)  # evicts the now-oldest (k2), NOT k1

      expect(capped.take("k2", "n2")).to be(false) # evicted
      expect(capped.take("k1", "n1b")).to be(true) # refreshed, survives
    end
  end

  # Reach the private @store hash for a size assertion without adding a public
  # accessor to the shipped surface.
  def store_size(store)
    store.instance_variable_get(:@store).size
  end
end
