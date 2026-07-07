# frozen_string_literal: true

RSpec.describe Kiosk::Server::AuthChallenge do
  let(:pem) { "-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----" }

  before { Kiosk.configure { |c| c.auth_challenge_ttl = 120 } }

  describe ".issue" do
    it "mints a nonce and records it with a TTL, consumable exactly once" do
      now    = Time.now
      result = described_class.issue(public_key_pem: pem, now: now)

      expect(result[:challenge]).to be_a(String)
      expect(result[:exp]).to eq(now.to_i + 120)
      expect(Kiosk.configuration.auth_challenge_store.take(pem, result[:challenge])).to be(true)
    end

    it "normalises the key so a whitespace-padded presentation still matches" do
      result = described_class.issue(public_key_pem: "#{pem}\n")
      expect(described_class.consume!(public_key_pem: pem, nonce: result[:challenge])).to be(true)
    end
  end

  describe ".consume!" do
    it "burns a matching live challenge" do
      c = described_class.issue(public_key_pem: pem)
      expect(described_class.consume!(public_key_pem: pem, nonce: c[:challenge])).to be(true)
    end

    it "raises Unauthenticated when no challenge matches" do
      expect {
        described_class.consume!(public_key_pem: pem, nonce: "nope")
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /challenge/)
    end

    it "raises Unauthenticated on replay (single-use)" do
      c = described_class.issue(public_key_pem: pem)
      described_class.consume!(public_key_pem: pem, nonce: c[:challenge])
      expect {
        described_class.consume!(public_key_pem: pem, nonce: c[:challenge])
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
    end
  end
end
