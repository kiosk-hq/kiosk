# frozen_string_literal: true

require "spec_helper"
require_relative "support"
require "jwt"
require "openssl"

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
        # Server accepts any bearer token (broken auth middleware)
        stub_exec_any(status: 200, body: { "rows" => [] })

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
        stub_exec_any(status: 401)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(401)
      end
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
  end
end
