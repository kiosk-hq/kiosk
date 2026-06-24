# frozen_string_literal: true

require "jwt"
require "openssl"

RSpec.describe Kiosk::Server::KycVerifier do
  let(:kyc_key)    { OpenSSL::PKey::RSA.generate(2048) }
  let(:kyc_issuer) { "https://kyc.example" }
  let(:identity)   { build_identity(user_id: "u-1", agent_id: "a-1") }
  let(:future)     { (Time.now + 600).to_i }
  let(:past)       { (Time.now - 600).to_i }

  before do
    Kiosk.configure do |c|
      c.kyc_issuer     = kyc_issuer
      c.kyc_public_key = kyc_key.public_key
    end
  end

  # Sign a KYC attestation payload with the test KYC key.
  def sign_kyc(payload)
    JWT.encode(payload, kyc_key, "RS256")
  end

  def valid_payload(**overrides)
    {
      sub: "u-1", level: "verified",
      iss: kyc_issuer, iat: (Time.now - 5).to_i, exp: future,
    }.merge(overrides)
  end

  # ─── happy path ───────────────────────────────────────────────────────

  describe ".verify" do
    it "returns claims hash for a valid attestation" do
      raw_jws = sign_kyc(valid_payload)
      claims  = described_class.verify(raw_jws: raw_jws, identity: identity)
      expect(claims[:sub]).to   eq("u-1")
      expect(claims[:level]).to eq("verified")
      expect(claims[:iss]).to   eq(kyc_issuer)
    end

    # ─── rejection paths ─────────────────────────────────────────────

    it "raises Errors::Forbidden when the iss does not match kyc_issuer" do
      raw_jws = sign_kyc(valid_payload(iss: "https://evil-kyc.example"))
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it "raises Errors::Forbidden when the sub does not match identity.user_id" do
      raw_jws = sign_kyc(valid_payload(sub: "u-other"))
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /subject/)
    end

    it "raises Errors::Forbidden for an expired attestation" do
      raw_jws = sign_kyc(valid_payload(exp: past))
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /expired/)
    end

    it "raises Errors::Forbidden for a tampered / wrong-key signature" do
      other_key = OpenSSL::PKey::RSA.generate(2048)
      raw_jws   = JWT.encode(valid_payload, other_key, "RS256")
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it "raises Errors::Forbidden when kyc_public_key is not configured" do
      Kiosk.configure { |c| c.kyc_public_key = nil }
      raw_jws = sign_kyc(valid_payload)
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /kyc_public_key/)
    end
  end
end
