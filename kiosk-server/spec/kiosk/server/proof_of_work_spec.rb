# frozen_string_literal: true

require "digest"

RSpec.describe Kiosk::Server::ProofOfWork do
  # ─── leading_zero_bits ────────────────────────────────────────────────

  describe ".leading_zero_bits" do
    it "returns 8 for a byte of 0x00" do
      expect(described_class.leading_zero_bits("\x00")).to eq(8)
    end

    it "returns 0 for a byte of 0xFF" do
      expect(described_class.leading_zero_bits("\xFF")).to eq(0)
    end

    it "returns 0 for a byte of 0x80" do
      expect(described_class.leading_zero_bits("\x80")).to eq(0)
    end

    it "returns 1 for a byte of 0x40" do
      expect(described_class.leading_zero_bits("\x40")).to eq(1)
    end

    it "returns 4 for a byte of 0x0F" do
      expect(described_class.leading_zero_bits("\x0F")).to eq(4)
    end

    it "spans into the second byte when the first is 0x00" do
      # 0x00 0xFF → 8 + 0 = 8
      expect(described_class.leading_zero_bits("\x00\xFF")).to eq(8)
    end

    it "spans into the second byte when the first is 0x00 and the second is 0x3F" do
      # 0x00 0x3F → 8 + 2 = 10
      expect(described_class.leading_zero_bits("\x00\x3F")).to eq(10)
    end

    it "returns 16 for two zero bytes" do
      expect(described_class.leading_zero_bits("\x00\x00")).to eq(16)
    end

    it "returns 0 for an empty bytes string" do
      expect(described_class.leading_zero_bits("")).to eq(0)
    end
  end

  # ─── valid? ───────────────────────────────────────────────────────────

  describe ".valid?" do
    let(:pem) { OpenSSL::PKey::RSA.generate(2048).public_key.to_pem }

    it "returns true for difficulty <= 0 (any pow accepted — plan 2/3 open registration)" do
      expect(described_class.valid?(public_key_pem: pem, pow: "anything", difficulty: 0)).to be true
      expect(described_class.valid?(public_key_pem: pem, pow: "anything", difficulty: -1)).to be true
    end

    it "accepts a pow that satisfies the difficulty" do
      # Brute-force a valid PoW for difficulty=1 (low enough to be fast in a test).
      pow = nil
      10_000.times do |i|
        candidate = i.to_s
        digest = Digest::SHA256.digest("#{pem}.#{candidate}")
        if described_class.leading_zero_bits(digest) >= 1
          pow = candidate
          break
        end
      end
      raise "Could not find a valid PoW in 10_000 tries for difficulty=1" unless pow

      expect(described_class.valid?(public_key_pem: pem, pow: pow, difficulty: 1)).to be true
    end

    it "rejects a pow that does NOT satisfy the difficulty" do
      # Find a pow that gives 0 leading zero bits for this pem, then require 1.
      failing_pow = nil
      10_000.times do |i|
        candidate = "bad-#{i}"
        digest = Digest::SHA256.digest("#{pem}.#{candidate}")
        if described_class.leading_zero_bits(digest) < 1
          failing_pow = candidate
          break
        end
      end
      raise "Could not find an invalid PoW in 10_000 tries" unless failing_pow

      expect(described_class.valid?(public_key_pem: pem, pow: failing_pow, difficulty: 1)).to be false
    end

    it "uses the exact formula SHA256(public_key_pem + '.' + pow)" do
      pow = "test-pow-1234"
      expected_digest = Digest::SHA256.digest("#{pem}.#{pow}")
      expected_zeros  = described_class.leading_zero_bits(expected_digest)

      # Check at exactly the computed difficulty — should be valid.
      expect(described_class.valid?(public_key_pem: pem, pow: pow, difficulty: expected_zeros)).to be true
      # One more bit required — should fail.
      expect(described_class.valid?(public_key_pem: pem, pow: pow, difficulty: expected_zeros + 1)).to be false
    end
  end

  # ─── configuration.registration_difficulty ────────────────────────────

  describe "Kiosk.configuration.registration_difficulty" do
    it "defaults to 0 (open registration, no PoW required)" do
      expect(Kiosk.configuration.registration_difficulty).to eq(0)
    end

    it "can be configured to a positive value" do
      Kiosk.configure { |c| c.registration_difficulty = 20 }
      expect(Kiosk.configuration.registration_difficulty).to eq(20)
    end

    it "is reset to 0 by Kiosk.reset!" do
      Kiosk.configure { |c| c.registration_difficulty = 20 }
      Kiosk.reset!
      expect(Kiosk.configuration.registration_difficulty).to eq(0)
    end
  end

  # ─── controller PoW gate ──────────────────────────────────────────────
  # (Integration with AgentsRegistrationController is tested in agent_registration_spec.rb)
  # These tests verify the gate logic in isolation via AgentRegistration itself
  # when difficulty > 0.

  describe "registration gate (difficulty > 0)" do
    let(:pem)         { OpenSSL::PKey::RSA.generate(2048).public_key.to_pem }
    let(:valid_pow)   do
      # Brute-force difficulty=1 PoW
      (0..9_999).each do |i|
        candidate = i.to_s
        digest = Digest::SHA256.digest("#{pem}.#{candidate}")
        return candidate if described_class.leading_zero_bits(digest) >= 1
      end
      raise "Could not find valid PoW for difficulty=1"
    end

    before do
      Kiosk.configure do |c|
        c.roles                  = %i[customer]
        c.schema                 = "kiosk"
        c.registration_difficulty = 1
      end
    end

    it "raises Errors::BadRequest when pow is missing and difficulty > 0" do
      expect {
        Kiosk::Server::AgentRegistration.call(
          name: "Agent", public_key_pem: pem, role: "customer", pow: nil,
        )
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /proof.of.work/i)
    end

    it "raises Errors::BadRequest when pow is invalid and difficulty > 0" do
      # Find a pow that definitely has 0 leading zero bits (fails difficulty=1).
      failing_pow = nil
      (0..9_999).each do |i|
        candidate = "bad-pow-#{i}"
        digest = Digest::SHA256.digest("#{pem}.#{candidate}")
        if Kiosk::Server::ProofOfWork.leading_zero_bits(digest) < 1
          failing_pow = candidate
          break
        end
      end
      raise "Could not find an invalid PoW in 10_000 tries" unless failing_pow

      expect {
        Kiosk::Server::AgentRegistration.call(
          name: "Agent", public_key_pem: pem, role: "customer", pow: failing_pow,
        )
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /proof.of.work/i)
    end
  end
end
