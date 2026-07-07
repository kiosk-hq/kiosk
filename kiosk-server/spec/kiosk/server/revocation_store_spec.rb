# frozen_string_literal: true

RSpec.describe Kiosk::Server::RevocationStore do
  subject(:store) { described_class.new }

  # Use current-era timestamps: watermarks older than the retention window are
  # pruned, so ancient epoch values (1000, 2000) would be evicted immediately.
  let(:base) { Time.now.to_i }

  it "revokes tokens issued strictly before the watermark" do
    store.revoke_all("agent-1", at: base)
    expect(store.revoked?(agent_id: "agent-1", iat: base - 1)).to be(true)
  end

  it "keeps tokens issued at or after the watermark (fresh login / replacement token)" do
    store.revoke_all("agent-1", at: base)
    expect(store.revoked?(agent_id: "agent-1", iat: base)).to be(false)
    expect(store.revoked?(agent_id: "agent-1", iat: base + 1)).to be(false)
  end

  it "does not revoke tokens for an agent that was never revoked" do
    expect(store.revoked?(agent_id: "other", iat: base)).to be(false)
  end

  it "treats nil agent_id / iat as not-revoked (never crashes the verifier)" do
    expect(store.revoked?(agent_id: nil, iat: base)).to be(false)
    expect(store.revoked?(agent_id: "agent-1", iat: nil)).to be(false)
  end

  it "only moves the watermark forward — a later revoke never un-revokes" do
    store.revoke_all("agent-1", at: base + 1000)
    store.revoke_all("agent-1", at: base) # earlier, ignored
    expect(store.revoked?(agent_id: "agent-1", iat: base + 500)).to be(true)
  end

  it "prunes watermarks older than the retention window" do
    short = described_class.new(retention: 10)
    short.revoke_all("agent-1", at: Time.now.to_i - 100) # well past retention
    short.prune!
    # Pruned — a token predating the (gone) watermark is no longer flagged.
    expect(short.revoked?(agent_id: "agent-1", iat: Time.now.to_i - 200)).to be(false)
  end
end
