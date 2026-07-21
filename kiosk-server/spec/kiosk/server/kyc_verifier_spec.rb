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

    # ─── named anonymized attributes ─────────────────────────────

    it "returns an empty attribute set for a bare binary attestation (backward-compat)" do
      claims = described_class.verify(raw_jws: sign_kyc(valid_payload), identity: identity)
      expect(claims[:attributes]).to eq({})
    end

    it "returns the granted named boolean attributes (String-keyed)" do
      raw_jws = sign_kyc(valid_payload(attributes: { age_over_18: true, licence_a: true }))
      claims  = described_class.verify(raw_jws: raw_jws, identity: identity)
      expect(claims[:attributes]).to eq("age_over_18" => true, "licence_a" => true)
    end

    it "drops any non-true attribute value (no truthy-but-not-true grants)" do
      raw_jws = sign_kyc(valid_payload(attributes: {
        age_over_18: true, licence_a: false, licence_b: "yes", extra: 1,
      }))
      claims = described_class.verify(raw_jws: raw_jws, identity: identity)
      expect(claims[:attributes]).to eq("age_over_18" => true)
    end

    it "raises Errors::Forbidden when attributes is not an object" do
      raw_jws = sign_kyc(valid_payload(attributes: ["age_over_18"]))
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /attributes must be an object/)
    end

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

    # On a bigint-PK host the authenticated Identity carries an Integer
    # user_id (the token `sub` round-trips as bigint) while the KYC provider
    # signs `sub` with the String id it was handed. The subject check must
    # compare as STRING on both sides, or every attestation on a bigint host is
    # wrongly Forbidden. (Mirrors MandateVerifier's bigint contract.)
    context "on a bigint-PK host (Integer identity, String attestation sub)" do
      let(:identity) { build_identity(user_id: 42, agent_id: 7) }

      it "verifies an Integer identity against a String attestation sub" do
        raw_jws = sign_kyc(valid_payload(sub: "42"))
        claims  = described_class.verify(raw_jws: raw_jws, identity: identity)
        expect(claims[:sub]).to eq("42")
        expect(claims[:level]).to eq("verified")
      end

      it "still rejects a genuinely different subject (43 != 42)" do
        raw_jws = sign_kyc(valid_payload(sub: "43"))
        expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /subject/)
      end
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

    # ─── I1: KYC level check ──────────────────────────────────────────────

    it "I1: raises Errors::Forbidden when level is not 'verified' (e.g. 'pending')" do
      raw_jws = sign_kyc(valid_payload(level: "pending"))
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /kyc level not verified/)
    end

    it "I1: raises Errors::Forbidden when level is missing entirely" do
      payload = valid_payload.reject { |k, _| k == :level }
      raw_jws = sign_kyc(payload)
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /kyc level not verified/)
    end

    # ─── I2: require exp (and iss, sub) claims ────────────────────────────

    it "I2: raises Errors::Forbidden when exp claim is absent" do
      payload = valid_payload.reject { |k, _| k == :exp }
      raw_jws = sign_kyc(payload)
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it "I2: raises Errors::Forbidden when iss claim is absent" do
      payload = valid_payload.reject { |k, _| k == :iss }
      raw_jws = sign_kyc(payload)
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it "I2: raises Errors::Forbidden when sub claim is absent" do
      payload = valid_payload.reject { |k, _| k == :sub }
      raw_jws = sign_kyc(payload)
      expect { described_class.verify(raw_jws: raw_jws, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end
  end
end
