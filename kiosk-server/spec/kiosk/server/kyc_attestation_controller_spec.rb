# frozen_string_literal: true

require "jwt"
require "openssl"

# The KycAttestationController wraps ActionController::API and only defines
# itself when Rails is loaded. Specs stub the DB layer exactly as other
# controller-adjacent tests do (see agent_registration_spec.rb, which also
# avoids a real DB).

RSpec.describe "Kiosk::Server::KycAttestationController (unit)" do
  let(:kyc_key)    { OpenSSL::PKey::RSA.generate(2048) }
  let(:kyc_issuer) { "https://kyc.example" }
  let(:user_id)    { "u-kyc-1" }
  let(:agent_id)   { "a-kyc-1" }
  let(:identity)   { build_identity(user_id: user_id, agent_id: agent_id) }
  let(:future)     { (Time.now + 600).to_i }

  before do
    Kiosk.configure do |c|
      c.kyc_issuer     = kyc_issuer
      c.kyc_public_key = kyc_key.public_key
    end
  end

  def valid_jws(**overrides)
    payload = {
      sub: user_id, level: "verified",
      iss: kyc_issuer, iat: (Time.now - 5).to_i, exp: future,
    }.merge(overrides)
    JWT.encode(payload, kyc_key, "RS256")
  end

  # ─── KycVerifier integration (the business logic the controller calls) ─

  describe "KycVerifier integration" do
    it "verifies a valid attestation and returns claims" do
      claims = Kiosk::Server::KycVerifier.verify(raw_jws: valid_jws, identity: identity)
      expect(claims[:sub]).to   eq(user_id)
      expect(claims[:level]).to eq("verified")
    end

    it "raises Errors::Forbidden for wrong issuer" do
      expect {
        Kiosk::Server::KycVerifier.verify(raw_jws: valid_jws(iss: "bad"), identity: identity)
      }.to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end
  end

  # ─── DefaultAgentIdp.kyc_verified? ────────────────────────────────────

  describe "DefaultAgentIdp.kyc_verified?" do
    let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }

    def stub_ar(result)
      fake_conn = Object.new.tap do |c|
        row = result
        c.define_singleton_method(:execute) { |_sql| row }
        c.define_singleton_method(:quote)   { |v| "'#{v}'" }
      end
      ar_base = Class.new { define_singleton_method(:connection) { fake_conn } }
      stub_const("ActiveRecord::Base", ar_base)
    end

    it "returns true when kyc_verified_at is not null" do
      stub_ar([{ "kyc_verified_at" => "2026-01-01T00:00:00Z" }])
      expect(idp.kyc_verified?(agent_id)).to be true
    end

    it "returns false when kyc_verified_at is null" do
      stub_ar([{ "kyc_verified_at" => nil }])
      expect(idp.kyc_verified?(agent_id)).to be false
    end

    it "returns false when the agent is not found" do
      stub_ar([])
      expect(idp.kyc_verified?(agent_id)).to be false
    end
  end
end
