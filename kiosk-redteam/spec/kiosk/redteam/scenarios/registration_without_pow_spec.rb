# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::RegistrationWithoutPow do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  describe "#call — non-vacuity" do
    let(:profile) { Kiosk::Redteam::Profile.new(pow_difficulty: 20) }

    context "when the server accepts registration without PoW (broken — BREACH)" do
      it "returns blocked: false" do
        # Both :skip and "0" succeed — server has no PoW gate
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            { status: 201, body: JSON.generate("agent_id" => "a1", "user_id" => "u1", "access_token" => "t1"),
              headers: { "Content-Type" => "application/json" } },
            { status: 201, body: JSON.generate("agent_id" => "a2", "user_id" => "u2", "access_token" => "t2"),
              headers: { "Content-Type" => "application/json" } },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to match(/201/)
      end
    end

    context "when the server rejects both no-PoW attempts (correct — BLOCKED)" do
      it "returns blocked: true on a 422 pow_required + 400 bad_request (no reliance on error code)" do
        # The scenario uses its own registration_rejected? check (status != 201, no token)
        # so it does NOT rely on Kiosk::Redteam.blocked? or the bad_request code.
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            { status: 422, body: JSON.generate("error" => { "code" => "pow_required" }),
              headers: { "Content-Type" => "application/json" } },
            { status: 400, body: JSON.generate("error" => { "code" => "bad_request" }),
              headers: { "Content-Type" => "application/json" } },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end

      it "returns blocked: true even when no domain error code is present (only status matters)" do
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            { status: 422, body: JSON.generate({}),
              headers: { "Content-Type" => "application/json" } },
            { status: 400, body: JSON.generate({}),
              headers: { "Content-Type" => "application/json" } },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end

    context "when only one attempt is blocked but not both (partial gate)" do
      it "returns blocked: false" do
        stub_request(:post, "#{BASE_URL}/kiosk/auth/register")
          .to_return(
            { status: 422, body: JSON.generate("error" => { "code" => "pow_required" }),
              headers: { "Content-Type" => "application/json" } },
            { status: 201, body: JSON.generate("agent_id" => "a2", "user_id" => "u2", "access_token" => "t2"),
              headers: { "Content-Type" => "application/json" } },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("201")
      end
    end
  end

  describe "#call — skip conditions" do
    it "skips when pow_difficulty is 0 (skip is not a pass)" do
      profile = Kiosk::Redteam::Profile.new(pow_difficulty: 0)
      verdict = scenario.call(client, profile)
      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SKIP")
    end
  end
end
