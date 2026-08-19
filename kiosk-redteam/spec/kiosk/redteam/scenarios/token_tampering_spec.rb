# frozen_string_literal: true

require "spec_helper"
require_relative "support"
require "jwt"
require "openssl"
require "json"
require "base64"

RSpec.describe Kiosk::Redteam::Scenarios::TokenTampering do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }
  let(:profile) { Kiosk::Redteam::Profile.new }

  # Issue a real RS256 JWT so tamper_token has a valid payload to mutate.
  let(:signing_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:valid_token) do
    now = Time.now.to_i
    JWT.encode({ sub: "user-b", role: "customer", exp: now + 3600, iat: now },
               signing_key, "RS256")
  end

  describe "#call — non-vacuity" do
    context "when the server accepts a tampered token (broken — BREACH)" do
      it "returns blocked: false" do
        # Registration returns a real RS256 JWT so tamper_token works correctly.
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            status:  201,
            body:    JSON.generate("agent_id" => "agent-b", "user_id" => "user-b",
                                   "access_token" => valid_token),
            headers: { "Content-Type" => "application/json" },
          )
        # Server accepts any bearer token (broken auth middleware).
        # The scenario probes with `client.query(name: "ping")` — GET /kiosk/ping.
        stub_query("ping", rows: [])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context "when the server rejects the tampered token (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            status:  201,
            body:    JSON.generate("agent_id" => "agent-b", "user_id" => "user-b",
                                   "access_token" => valid_token),
            headers: { "Content-Type" => "application/json" },
          )
        captured = nil
        stub_request(:get, verb_url("ping"))
          .with { |req| captured = req; true }
          .to_return(problem_return("unauthenticated"))

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(401)
        # The probe carried the TAMPERED token, not the issued one.
        bearer = captured.headers["Authorization"].sub("Bearer ", "")
        expect(bearer).not_to eq(valid_token)
        expect(bearer.split(".").last).to eq(valid_token.split(".").last)
      end
    end
  end

  # ── K-728 ────────────────────────────────────────────────────────────────
  #
  # A signature that no longer matches its payload is an AUTHENTICATION
  # failure. A 403 means the token was accepted and then authorized against; a
  # 402 means a toll fired ahead of the signature check. Both used to score
  # BLOCKED off the permissive blocked? set.
  describe "#call — only a 401 proves the signature was checked (K-728)" do
    def stub_register_with_real_jwt
      stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
        .to_return(status:  201,
                   body:    JSON.generate("agent_id" => "agent-b", "user_id" => "user-b",
                                          "access_token" => valid_token),
                   headers: { "Content-Type" => "application/json" })
    end

    { 403 => "forbidden", 402 => "pow_required" }.each do |status, code|
      it "returns blocked: false when the tampered token is answered #{status}" do
        stub_register_with_real_jwt
        stub_query("ping", status: status, code: code)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(status)
        expect(verdict.detail).to include("want status 401")
      end
    end

    it "returns blocked: false on a 500" do
      stub_register_with_real_jwt
      stub_query("ping", status: 500, code: "forbidden")

      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  describe "tamper_token (private helper)" do
    let(:scenario_instance) { described_class.new }

    it "produces a token with a different payload segment" do
      original = valid_token
      tampered = scenario_instance.send(:tamper_token, original)
      orig_parts = original.split(".")
      tamp_parts = tampered.split(".")
      expect(tamp_parts[1]).not_to eq(orig_parts[1])   # payload changed
      expect(tamp_parts[2]).to eq(orig_parts[2])        # signature unchanged
    end

    it "produces a token that fails RS256 verification" do
      tampered = scenario_instance.send(:tamper_token, valid_token)
      expect {
        JWT.decode(tampered, signing_key.public_key, true, algorithms: ["RS256"])
      }.to raise_error(JWT::DecodeError)
    end

    # The role branch (claims["role"]) is covered by the token above. The
    # remaining branches (sub / exp / else) are only reached for tokens that
    # carry no `role` claim — e.g. a role-absent provider.
    # Decode the tampered payload to prove the intended claim was flipped.
    def flipped_claims(scenario_instance, token)
      payload_b64 = scenario_instance.send(:tamper_token, token).split(".")[1]
      padded = payload_b64 + ("=" * ((4 - payload_b64.length % 4) % 4))
      JSON.parse(Base64.urlsafe_decode64(padded))
    end

    context "when the token carries no role claim (role-absent provider)" do
      let(:sub_token) do
        now = Time.now.to_i
        JWT.encode({ sub: "user-b", exp: now + 3600, iat: now }, signing_key, "RS256")
      end

      it "flips the sub claim" do
        claims = flipped_claims(scenario_instance, sub_token)
        expect(claims["sub"]).to eq("user-b-tampered")
      end

      it "still produces a signature-invalid token" do
        tampered = scenario_instance.send(:tamper_token, sub_token)
        expect {
          JWT.decode(tampered, signing_key.public_key, true, algorithms: ["RS256"])
        }.to raise_error(JWT::DecodeError)
      end
    end

    context "when the token carries only an exp claim (no role, no sub)" do
      let(:exp_token) do
        now = Time.now.to_i
        JWT.encode({ exp: now + 3600, iat: now }, signing_key, "RS256")
      end

      it "bumps the exp claim by 999_999 seconds" do
        now = Time.now.to_i
        claims = flipped_claims(scenario_instance, exp_token)
        expect(claims["exp"]).to eq(now + 3600 + 999_999)
      end
    end

    context "when the token carries none of role / sub / exp" do
      let(:sentinel_token) do
        JWT.encode({ iat: Time.now.to_i, foo: "bar" }, signing_key, "RS256")
      end

      it "injects the __tamper__ sentinel claim" do
        claims = flipped_claims(scenario_instance, sentinel_token)
        expect(claims["__tamper__"]).to be(true)
      end
    end
  end
end
