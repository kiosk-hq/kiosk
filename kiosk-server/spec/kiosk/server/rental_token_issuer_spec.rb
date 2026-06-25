# frozen_string_literal: true

# Known-answer test vector (firmware host-test fixtures — MUST NOT CHANGE).
# These are deterministic outputs of RentalTokenIssuer (token v2) for the fixed
# inputs below. firmware/host_test.c feeds these exact values to the C verify function.
#
#   dev_private_pem  = DevUnlockKey::DEV_PRIVATE_PEM
#   scooter_code     = "SK-001"
#   reservation_id   = "resv-1"
#   now              = 1750000000
#   jti (stubbed)    = "aabbccddeeff00112233445566778899"
#
#   message         : kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899
#   signature b64url: 1Vx7nv8xgznLwWgdsS_MhWi1W1fhMQQWSgi1CPRVO3osohmlw_PhaTS9ZJaBOx9yeQZfzn2k8J4JjSXPd12SBA
#   pubkey hex      : 8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd

require "kiosk/server/rental_token_issuer"

RSpec.describe Kiosk::Server::RentalTokenIssuer do
  # Fixed dev keypair — same key used in kiosk-demo-skooti initializer.
  DEV_PRIVATE_PEM = <<~PEM.freeze
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEINeFKJGXag/XX62rnmCiS2NKnbvRliRBDuuTbrxQ/n3R
    -----END PRIVATE KEY-----
  PEM

  DEV_PUBKEY_HEX = "8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd"

  let(:dev_key) { OpenSSL::PKey.read(DEV_PRIVATE_PEM) }

  before do
    Kiosk.configure { |c| c.unlock_signing_key = dev_key }
  end

  # ─── issue ───────────────────────────────────────────────────────────────

  describe ".issue" do
    it "returns a string in the wire-token format '<message>.<base64url_sig>'" do
      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-42",
        now:            1_750_000_000,
      )
      parts = token.split(".")
      expect(parts.length).to be >= 2
      # message = kiosk-rental-v1|scooter_code|reservation_id|iat|exp|jti — 6 pipe-separated fields
      message_parts = parts[..-2].join(".").split("|")
      expect(message_parts.length).to eq(6)
    end

    it "embeds the context tag, scooter_code and reservation_id in the message" do
      token = described_class.issue(
        scooter_code:   "SK-007",
        reservation_id: "resv-99",
        now:            1_750_000_000,
      )
      message = token.split(".")[..-2].join(".")
      expect(message).to start_with("kiosk-rental-v1|SK-007|resv-99|")
    end

    it "sets iat = now and exp = now + ttl (default 900)" do
      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      message = token.split(".")[..-2].join(".")
      fields  = message.split("|")
      expect(fields[3].to_i).to eq(1_750_000_000)          # iat (field 3 in v2)
      expect(fields[4].to_i).to eq(1_750_000_000 + 900)    # exp (field 4 in v2)
    end

    it "respects a custom ttl" do
      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
        ttl:            300,
      )
      message = token.split(".")[..-2].join(".")
      fields  = message.split("|")
      expect(fields[4].to_i).to eq(1_750_000_000 + 300)  # exp is field 4 in v2
    end

    it "includes a 32-char hex jti as the last field in the message" do
      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      message = token.split(".")[..-2].join(".")
      jti     = message.split("|").last
      expect(jti).to match(/\A[0-9a-f]{32}\z/)
    end

    it "produces different tokens for the same inputs (fresh jti each call)" do
      opts = { scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000 }
      t1   = described_class.issue(**opts)
      t2   = described_class.issue(**opts)
      expect(t1).not_to eq(t2)
    end
  end

  # ─── verify ──────────────────────────────────────────────────────────────

  describe ".verify" do
    it "round-trips: issue then verify returns the expected claims" do
      token  = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-42",
        now:            1_750_000_000,
      )
      claims = described_class.verify(token: token, now: 1_750_000_000)

      expect(claims).not_to be_nil
      expect(claims[:scooter_code]).to   eq("SK-001")
      expect(claims[:reservation_id]).to eq("resv-42")
      expect(claims[:iat]).to            eq(1_750_000_000)
      expect(claims[:exp]).to            eq(1_750_000_000 + 900)
      expect(claims[:jti]).to            match(/\A[0-9a-f]{32}\z/)
    end

    it "returns nil when the signature is tampered (flip one base64 char)" do
      token   = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      # Flip the last char of the base64url signature
      tampered = token[0..-2] + (token[-1] == "A" ? "B" : "A")
      expect(described_class.verify(token: tampered, now: 1_750_000_000)).to be_nil
    end

    it "returns nil when the message fields are tampered (wrong scooter)" do
      token   = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      # Swap scooter code in message but keep original signature
      sig_b64 = token.split(".").last
      message = token.split(".")[..-2].join(".")
      tampered = message.sub("SK-001", "SK-999") + ".#{sig_b64}"
      expect(described_class.verify(token: tampered, now: 1_750_000_000)).to be_nil
    end

    it "returns nil when the token is expired (now > exp)" do
      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      # exp = 1_750_000_900; check at now = exp+1
      expect(
        described_class.verify(token: token, now: 1_750_000_000 + 900 + 1)
      ).to be_nil
    end

    it "returns claims when now == exp (boundary — exp is inclusive)" do
      token  = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      claims = described_class.verify(token: token, now: 1_750_000_000 + 900)
      expect(claims).not_to be_nil
    end

    it "returns nil for a completely invalid token string" do
      expect(described_class.verify(token: "garbage", now: 1_750_000_000)).to be_nil
    end

    it "returns nil for an empty string" do
      expect(described_class.verify(token: "", now: 1_750_000_000)).to be_nil
    end
  end

  # ─── public_key_pem ───────────────────────────────────────────────────────

  describe ".public_key_pem" do
    it "returns a PEM string containing a PUBLIC KEY" do
      pem = described_class.public_key_pem
      expect(pem).to include("BEGIN PUBLIC KEY")
    end

    it "returns the public side of the configured unlock_signing_key" do
      pem = described_class.public_key_pem
      # Round-trip: load the PEM and verify a signature made with the private key
      pub   = OpenSSL::PKey.read(pem)
      token = described_class.issue(scooter_code: "SK-001", reservation_id: "r-1", now: 1_750_000_000)
      sig   = Base64.urlsafe_decode64(token.split(".").last)
      msg   = token.split(".")[..-2].join(".")
      expect(pub.verify(nil, sig, msg)).to be true
    end
  end

  # ─── public_key_raw32_hex ─────────────────────────────────────────────────

  describe ".public_key_raw32_hex" do
    it "returns a 64-char lowercase hex string (32 bytes)" do
      hex = described_class.public_key_raw32_hex
      expect(hex).to match(/\A[0-9a-f]{64}\z/)
    end

    it "matches the dev pubkey hex fixture (firmware bakes this)" do
      expect(described_class.public_key_raw32_hex).to eq(DEV_PUBKEY_HEX)
    end
  end

  # ─── configuration ────────────────────────────────────────────────────────

  describe "Kiosk.configuration.unlock_signing_key" do
    it "defaults to nil" do
      Kiosk.reset!
      expect(Kiosk.configuration.unlock_signing_key).to be_nil
    end

    it "can be set and read back" do
      Kiosk.configure { |c| c.unlock_signing_key = dev_key }
      expect(Kiosk.configuration.unlock_signing_key).to eq(dev_key)
    end

    it "is reset to nil by Kiosk.reset!" do
      Kiosk.configure { |c| c.unlock_signing_key = dev_key }
      Kiosk.reset!
      expect(Kiosk.configuration.unlock_signing_key).to be_nil
    end
  end

  # ─── KNOWN-ANSWER VECTOR (firmware fixtures — MUST NOT CHANGE) ────────────

  describe "known-answer vector" do
    # These values are the source of truth for:
    #   - firmware/host_test.c  (T3)
    #   - kiosk-demo-skooti lock-sim (T2)
    # Changing them breaks the C cross-check test. Record them verbatim.
    #
    # Token v2: field 0 is the domain-separation context tag "kiosk-rental-v1".
    #
    #   dev_private_pem  = DevUnlockKey::DEV_PRIVATE_PEM
    #   scooter_code     = "SK-001"
    #   reservation_id   = "resv-1"
    #   now              = 1750000000
    #   jti (stubbed)    = "aabbccddeeff00112233445566778899"
    #
    KNOWN_MESSAGE   = "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
    KNOWN_SIG_B64   = "1Vx7nv8xgznLwWgdsS_MhWi1W1fhMQQWSgi1CPRVO3osohmlw_PhaTS9ZJaBOx9yeQZfzn2k8J4JjSXPd12SBA"
    KNOWN_PUBKEY_HEX = "8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd"

    it "produces the exact known message and base64url signature for fixed inputs" do
      allow(SecureRandom).to receive(:hex).with(16).and_return("aabbccddeeff00112233445566778899")

      token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )

      sig_b64 = token.split(".").last
      message = token.split(".")[..-2].join(".")

      expect(message).to   eq(KNOWN_MESSAGE)
      expect(sig_b64).to   eq(KNOWN_SIG_B64)
    end

    it "verifies the known-answer token at now = iat" do
      wire_token = "#{KNOWN_MESSAGE}.#{KNOWN_SIG_B64}"
      claims     = described_class.verify(token: wire_token, now: 1_750_000_000)

      expect(claims).not_to be_nil
      expect(claims[:scooter_code]).to   eq("SK-001")
      expect(claims[:reservation_id]).to eq("resv-1")
    end

    it "returns the known 32-byte pubkey hex" do
      expect(described_class.public_key_raw32_hex).to eq(KNOWN_PUBKEY_HEX)
    end
  end

  # ─── DOMAIN SEPARATION — tag check ───────────────────────────────────────

  describe "domain separation — context tag" do
    it "returns nil when field 0 is not 'kiosk-rental-v1' (tampered tag)" do
      # Build a valid-signature token with a wrong tag field, then verify rejects it.
      allow(SecureRandom).to receive(:hex).with(16).and_return("aabbccddeeff00112233445566778899")
      valid_token = described_class.issue(
        scooter_code:   "SK-001",
        reservation_id: "resv-1",
        now:            1_750_000_000,
      )
      # Replace the context tag in the message with something wrong.
      # The signature will no longer verify — this tests that verify returns nil
      # for any token that doesn't match the CONTEXT_TAG in field 0.
      sig_b64 = valid_token.split(".").last
      message = valid_token.split(".")[..-2].join(".")
      tampered_message = message.sub("kiosk-rental-v1", "kiosk-rental-v0")
      tampered_token   = "#{tampered_message}.#{sig_b64}"

      expect(described_class.verify(token: tampered_token, now: 1_750_000_000)).to be_nil
    end
  end
end
