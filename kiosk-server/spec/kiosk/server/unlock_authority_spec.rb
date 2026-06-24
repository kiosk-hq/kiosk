# frozen_string_literal: true

# Known-answer test vectors (firmware host-test fixtures — MUST NOT CHANGE).
# These are deterministic outputs of UnlockAuthority for the inputs below.
# Part C host_test.c feeds these exact values to the C verify function.
#
#   master_key     = "dev-master-key-0001"   (UTF-8 bytes)
#   scooter_id     = "SK-001"
#   nonce_hex      = "00112233445566778899aabbccddeeff"
#   reservation_id = "resv-1"
#
#   K_lock hex : d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a
#   mac        : 896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f

RSpec.describe Kiosk::Server::UnlockAuthority do
  let(:master_key)     { "dev-master-key-0001" }
  let(:scooter_id)     { "SK-001" }
  let(:nonce_hex)      { "00112233445566778899aabbccddeeff" }
  let(:reservation_id) { "resv-1" }

  # Known-answer constants — locked forever (firmware depends on these).
  EXPECTED_K_LOCK_HEX = "d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a"
  EXPECTED_MAC        = "896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f"

  before do
    Kiosk.configure { |c| c.unlock_master_key = master_key }
  end

  # ─── lock_key ─────────────────────────────────────────────────────────

  describe ".lock_key" do
    it "returns 32 raw bytes" do
      key = described_class.lock_key(scooter_id)
      expect(key.bytesize).to eq(32)
      expect(key.encoding).to eq(Encoding::BINARY)
    end

    it "matches the known-answer K_lock for the test vector" do
      key = described_class.lock_key(scooter_id)
      expect(key.unpack1("H*")).to eq(EXPECTED_K_LOCK_HEX)
    end

    it "produces different keys for different scooter_ids (diversification)" do
      key_a = described_class.lock_key("SK-001")
      key_b = described_class.lock_key("SK-002")
      expect(key_a).not_to eq(key_b)
    end

    it "is deterministic — same inputs always yield the same key" do
      expect(described_class.lock_key(scooter_id)).to eq(described_class.lock_key(scooter_id))
    end
  end

  # ─── mac ──────────────────────────────────────────────────────────────

  describe ".mac" do
    it "returns a hex string of 64 characters (SHA-256 = 32 bytes = 64 hex chars)" do
      result = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      expect(result).to be_a(String)
      expect(result.length).to eq(64)
      expect(result).to match(/\A[0-9a-f]+\z/)
    end

    it "matches the known-answer mac for the firmware host test vector" do
      result = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      expect(result).to eq(EXPECTED_MAC)
    end

    it "is sensitive to scooter_id (different lock, different mac)" do
      mac_a = described_class.mac(
        scooter_id: "SK-001", nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      mac_b = described_class.mac(
        scooter_id: "SK-002", nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      expect(mac_a).not_to eq(mac_b)
    end

    it "is sensitive to nonce_hex (replay detection — different nonce, different mac)" do
      mac_a = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      mac_b = described_class.mac(
        scooter_id: scooter_id, nonce_hex: "ffffffffffffffffffffffffffffffff", reservation_id: reservation_id,
      )
      expect(mac_a).not_to eq(mac_b)
    end

    it "is sensitive to reservation_id (authorization binding)" do
      mac_a = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      mac_b = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: "resv-OTHER",
      )
      expect(mac_a).not_to eq(mac_b)
    end

    it "uses the message format 'scooter_id|nonce_hex|reservation_id' (exact byte layout)" do
      # Verify by recomputing manually with the same lock_key.
      lock_key       = described_class.lock_key(scooter_id)
      expected_msg   = "#{scooter_id}|#{nonce_hex}|#{reservation_id}"
      expected_mac   = OpenSSL::HMAC.hexdigest("SHA256", lock_key, expected_msg)

      result = described_class.mac(
        scooter_id: scooter_id, nonce_hex: nonce_hex, reservation_id: reservation_id,
      )
      expect(result).to eq(expected_mac)
    end
  end

  # ─── unlock_master_key config ─────────────────────────────────────────

  describe "Kiosk.configuration.unlock_master_key" do
    it "defaults to nil" do
      Kiosk.reset!
      expect(Kiosk.configuration.unlock_master_key).to be_nil
    end

    it "can be set and read back" do
      Kiosk.configure { |c| c.unlock_master_key = "my-secret-key" }
      expect(Kiosk.configuration.unlock_master_key).to eq("my-secret-key")
    end

    it "is reset to nil by Kiosk.reset!" do
      Kiosk.configure { |c| c.unlock_master_key = "some-key" }
      Kiosk.reset!
      expect(Kiosk.configuration.unlock_master_key).to be_nil
    end
  end
end
