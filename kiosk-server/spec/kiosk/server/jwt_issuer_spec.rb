# frozen_string_literal: true

require "jwt"

RSpec.describe Kiosk::Server::JwtIssuer do
  # Cache one keypair per file — RSA generation is expensive.
  before(:all) do
    @rsa1 = OpenSSL::PKey::RSA.generate(2048)
    @rsa2 = OpenSSL::PKey::RSA.generate(2048)
  end

  let(:key)        { Kiosk::Server::SigningKey.new(@rsa1) }
  let(:other_key)  { Kiosk::Server::SigningKey.new(@rsa2) }
  let(:jwks)       { Kiosk::Server::Jwks.build(keys: [key]) }
  let(:issuer)     { "https://combette.example/kiosk" }
  let(:audience)   { "https://claude.ai/agent/alice" }

  before do
    Kiosk.configure do |c|
      c.issuer      = issuer
      c.signing_key = key
    end
  end

  describe ".issue" do
    it "produces a JWT carrying the supplied claims and the standard time bounds" do
      token = described_class.issue(
        claims:   { sub: "user-1", role: "customer" },
        audience: audience,
      )
      payload, header = ::JWT.decode(token, key.rsa.public_key, true, algorithms: ["RS256"])

      expect(header["alg"]).to eq("RS256")
      expect(header["kid"]).to eq(key.kid)
      expect(header["typ"]).to eq("JWT")
      expect(payload["sub"]).to eq("user-1")
      expect(payload["role"]).to eq("customer")
      expect(payload["iss"]).to eq(issuer)
      expect(payload["aud"]).to eq(audience)
      expect(payload["iat"]).to be_a(Integer)
      expect(payload["exp"]).to be > payload["iat"]
      expect(payload["jti"]).to match(/\A[0-9a-f-]+\z/) # UUID
    end

    it "defaults to a one-hour lifetime" do
      now = Time.utc(2026, 6, 10, 12, 0, 0)
      token = described_class.issue(
        claims:   { sub: "user-1" },
        audience: audience,
        now:      now,
      )
      payload, = ::JWT.decode(token, key.rsa.public_key, true,
                              algorithms: ["RS256"], verify_expiration: false)
      expect(payload["exp"] - payload["iat"]).to eq(3600)
    end

    it "honours an `expires_in` override" do
      token = described_class.issue(
        claims:     { sub: "user-1" },
        audience:   audience,
        expires_in: 60,
      )
      payload, = ::JWT.decode(token, key.rsa.public_key, true, algorithms: ["RS256"])
      expect(payload["exp"] - payload["iat"]).to eq(60)
    end

    it "lets caller-supplied jti pass through (idempotency keys etc.)" do
      token = described_class.issue(
        claims:   { sub: "user-1", jti: "fixed-id" },
        audience: audience,
      )
      payload, = ::JWT.decode(token, key.rsa.public_key, true, algorithms: ["RS256"])
      expect(payload["jti"]).to eq("fixed-id")
    end

    it "raises when no issuer is configured" do
      Kiosk.configure { |c| c.issuer = nil }
      expect {
        described_class.issue(claims: { sub: "u" }, audience: audience)
      }.to raise_error(ArgumentError, /issuer is required/)
    end

    it "raises when the signing key is public-only" do
      pub_only = Kiosk::Server::SigningKey.from_pem(key.rsa.public_key.to_pem)
      Kiosk.configure { |c| c.signing_key = pub_only }
      expect {
        described_class.issue(claims: { sub: "u" }, audience: audience)
      }.to raise_error(ArgumentError, /private key/)
    end
  end

  describe ".verify" do
    let(:token) {
      described_class.issue(claims: { sub: "user-1", role: "customer" }, audience: audience)
    }

    it "round-trips an issued token and returns symbol-keyed claims" do
      claims = described_class.verify(token: token, jwks: jwks, audience: audience)
      expect(claims).to include(
        sub:  "user-1",
        role: "customer",
        iss:  issuer,
        aud:  audience,
      )
      expect(claims[:exp]).to be > claims[:iat]
    end

    it "accepts the issuer when supplied and matching" do
      claims = described_class.verify(
        token: token, jwks: jwks, audience: audience, issuer: issuer,
      )
      expect(claims[:iss]).to eq(issuer)
    end

    it "rejects a wrong audience" do
      expect {
        described_class.verify(token: token, jwks: jwks, audience: "https://wrong.example")
      }.to raise_error(described_class::AudienceError)
    end

    it "rejects an expired token" do
      old = described_class.issue(
        claims:     { sub: "u" },
        audience:   audience,
        expires_in: -3600, # already expired
      )
      expect {
        described_class.verify(token: old, jwks: jwks, audience: audience)
      }.to raise_error(described_class::ExpiredError)
    end

    it "rejects a token signed by a key not in the JWKS" do
      Kiosk.configure { |c| c.signing_key = other_key }
      foreign = described_class.issue(claims: { sub: "u" }, audience: audience)
      expect {
        described_class.verify(token: foreign, jwks: jwks, audience: audience)
      }.to raise_error(described_class::SignatureError)
    end

    it "rejects a malformed token" do
      expect {
        described_class.verify(token: "not.a.jwt", jwks: jwks, audience: audience)
      }.to raise_error(described_class::InvalidError)
    end

    it "rejects a tampered payload" do
      header, payload, signature = token.split(".")
      tampered_payload = Base64.urlsafe_encode64(
        JSON.generate(JSON.parse(Base64.urlsafe_decode64(payload + "=" * ((4 - payload.size % 4) % 4))).merge("role" => "admin")),
        padding: false,
      )
      tampered = [header, tampered_payload, signature].join(".")
      expect {
        described_class.verify(token: tampered, jwks: jwks, audience: audience)
      }.to raise_error(described_class::SignatureError)
    end

    describe "revocation" do
      let(:agent_token) {
        described_class.issue(claims: { sub: "u", agent_id: "a-1" }, audience: audience)
      }

      it "rejects a token whose agent has been revoked as of now" do
        store = Kiosk::Server::RevocationStore.new
        agent_token # issue first (iat = now)
        store.revoke_all("a-1", at: Time.now.to_i + 120) # watermark ahead of iat
        expect {
          described_class.verify(token: agent_token, jwks: jwks, audience: audience, revocation_store: store)
        }.to raise_error(described_class::RevokedError)
      end

      it "accepts a token issued after the revocation watermark (fresh login survives)" do
        store = Kiosk::Server::RevocationStore.new
        store.revoke_all("a-1", at: Time.now.to_i - 120) # watermark in the past
        fresh = described_class.issue(claims: { sub: "u", agent_id: "a-1" }, audience: audience)
        expect {
          described_class.verify(token: fresh, jwks: jwks, audience: audience, revocation_store: store)
        }.not_to raise_error
      end

      it "skips the check when revocation_store is nil" do
        store = Kiosk::Server::RevocationStore.new
        store.revoke_all("a-1", at: Time.now.to_i + 120)
        expect {
          described_class.verify(token: agent_token, jwks: jwks, audience: audience, revocation_store: nil)
        }.not_to raise_error
      end
    end

    it "respects clock skew leeway for slightly-in-the-future iat" do
      future = described_class.issue(
        claims:   { sub: "u" },
        audience: audience,
        now:      Time.now + 30, # 30s in the future
      )
      # Default leeway is 60s; should still accept.
      expect {
        described_class.verify(token: future, jwks: jwks, audience: audience)
      }.not_to raise_error
    end
  end

  describe ".normalize_jwks input polymorphism" do
    let(:token) {
      described_class.issue(claims: { sub: "u" }, audience: audience)
    }

    it "accepts an Array<SigningKey>" do
      expect {
        described_class.verify(token: token, jwks: [key], audience: audience)
      }.not_to raise_error
    end

    it "accepts a single SigningKey" do
      expect {
        described_class.verify(token: token, jwks: key, audience: audience)
      }.not_to raise_error
    end

    it "accepts a fully-formed JWKS Hash" do
      expect {
        described_class.verify(token: token, jwks: { keys: [key.to_jwk] }, audience: audience)
      }.not_to raise_error
    end

    it "rejects an unsupported input type" do
      expect {
        described_class.verify(token: token, jwks: 42, audience: audience)
      }.to raise_error(ArgumentError, /jwks must be/)
    end
  end
end
