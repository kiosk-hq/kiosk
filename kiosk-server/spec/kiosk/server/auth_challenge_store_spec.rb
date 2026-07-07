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
end
