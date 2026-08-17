# frozen_string_literal: true

require "jwt"
require "openssl"

# Unit-covers the business logic BEHIND the KYC attestation endpoint —
# {KycVerifier.verify} and {DefaultAgentIdp#kyc_verified?} — without a Rails
# stack. The controller's HTTP dispatch (auth resolution, body parsing,
# response envelope, agent-only rule) is exercised end-to-end in
# controller_auth_spec.rb, which loads and dispatches the real controller via
# ActionController::Metal.

RSpec.describe "Kiosk::Server KYC attestation logic (unit)" do
  let(:kyc_key)      { OpenSSL::PKey::RSA.generate(2048) }
  let(:kyc_issuer)   { "https://kyc.example" }
  let(:kyc_audience) { "acme-operator" }
  let(:user_id)      { "u-kyc-1" }
  let(:agent_id)     { "a-kyc-1" }
  let(:identity)     { build_identity(user_id: user_id, agent_id: agent_id) }
  let(:future)       { (Time.now + 600).to_i }

  before do
    Kiosk.configure do |c|
      c.kyc_issuer     = kyc_issuer
      c.kyc_audience   = kyc_audience
      c.kyc_public_key = kyc_key.public_key
    end
  end

  def valid_jws(**overrides)
    payload = {
      sub: user_id, level: "verified",
      iss: kyc_issuer, aud: kyc_audience, iat: (Time.now - 5).to_i, exp: future,
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

    # K-782: the IdP's four agent lookups became ONE bind-parameterised
    # statement on `lease_connection`, so the fake answers `exec_query` and
    # offers no `quote` at all — a call to it would now be a NoMethodError,
    # which is the point.
    def stub_ar(result)
      fake_conn = Object.new.tap do |c|
        rows = result
        c.define_singleton_method(:exec_query) { |_sql, _name = nil, _binds = []| rows }
      end
      ar_base = Class.new { define_singleton_method(:lease_connection) { fake_conn } }
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

  # ─── DefaultAgentIdp attribute queries ────────────────────────
  describe "DefaultAgentIdp KYC attributes" do
    let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }

    # K-782: the IdP's four agent lookups became ONE bind-parameterised
    # statement on `lease_connection`, so the fake answers `exec_query` and
    # offers no `quote` at all — a call to it would now be a NoMethodError,
    # which is the point.
    def stub_ar(result)
      fake_conn = Object.new.tap do |c|
        rows = result
        c.define_singleton_method(:exec_query) { |_sql, _name = nil, _binds = []| rows }
      end
      ar_base = Class.new { define_singleton_method(:lease_connection) { fake_conn } }
      stub_const("ActiveRecord::Base", ar_base)
    end

    describe "#kyc_attributes" do
      it "parses a jsonb String into a hash" do
        stub_ar([{ "kyc_attributes" => '{"age_over_18":true,"licence_a":true}' }])
        expect(idp.kyc_attributes(agent_id)).to eq("age_over_18" => true, "licence_a" => true)
      end

      it "passes through an already-parsed hash" do
        stub_ar([{ "kyc_attributes" => { "age_over_18" => true } }])
        expect(idp.kyc_attributes(agent_id)).to eq("age_over_18" => true)
      end

      it "returns {} when the column is null" do
        stub_ar([{ "kyc_attributes" => nil }])
        expect(idp.kyc_attributes(agent_id)).to eq({})
      end

      it "returns {} when the agent is not found" do
        stub_ar([])
        expect(idp.kyc_attributes(agent_id)).to eq({})
      end
    end

    describe "#kyc_has_attributes?" do
      it "is true when every required attribute is present-and-true" do
        stub_ar([{ "kyc_attributes" => '{"age_over_18":true,"licence_a":true}' }])
        expect(idp.kyc_has_attributes?(agent_id, %w[age_over_18 licence_a])).to be true
      end

      it "is false when a required attribute is missing" do
        stub_ar([{ "kyc_attributes" => '{"age_over_18":true}' }])
        expect(idp.kyc_has_attributes?(agent_id, %w[age_over_18 licence_a])).to be false
      end

      it "accepts Symbol required names" do
        stub_ar([{ "kyc_attributes" => '{"age_over_18":true}' }])
        expect(idp.kyc_has_attributes?(agent_id, [:age_over_18])).to be true
      end
    end
  end
end
