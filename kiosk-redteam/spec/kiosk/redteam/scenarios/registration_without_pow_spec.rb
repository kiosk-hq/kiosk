# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::RegistrationWithoutPow do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  # The scenario posts /register up to three times, in order:
  #   1. pow: :skip   2. pow: "0"   3. the CONTROL solve (only when 1 and 2
  #   were both refused, since a success is already conclusive).
  def register_returns(*responses)
    stub_request(:post, "#{BASE_URL}/kiosk/auth/register").to_return(*responses)
  end

  def refused(status, body = {})
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end

  def issued(suffix = "ctl")
    { status:  201,
      body:    JSON.generate("agent_id" => "a-#{suffix}", "user_id" => "u-#{suffix}",
                             "access_token" => "tok-#{suffix}"),
      headers: { "Content-Type" => "application/json" } }
  end

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

    context "when the server rejects both no-PoW attempts AND issues on a solved one (correct — BLOCKED)" do
      it "returns blocked: true on a 422 pow_required + 400 bad_request (no reliance on error code)" do
        # The scenario uses its own rejection check (status != 201, no token, not
        # a crash) so it does NOT rely on Kiosk::Redteam.blocked? or on the
        # bad_request code.
        register_returns(
          refused(422, "error" => { "code" => "pow_required" }),
          refused(400, "error" => { "code" => "bad_request" }),
          issued,
        )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end

      # K-730 narrowed this from "only status matters" to "status, plus a
      # control proving the endpoint issues when the proof IS solved".
      it "returns blocked: true even when no domain error code is present" do
        register_returns(refused(422), refused(400), issued)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end

      it "reports the control's 201 as the verdict status" do
        register_returns(refused(422), refused(400), issued)

        expect(scenario.call(client, profile).status).to eq(201)
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

  # ── K-730 ────────────────────────────────────────────────────────────────
  #
  # "Both attempts were refused" is satisfied by a server that refuses
  # EVERYTHING. This block overturns the assertion above that a bare status was
  # sufficient: the control leg is what makes the two refusals evidence of a
  # PoW gate rather than evidence of an outage.
  describe "#call — the refusals must be earned (K-730)" do
    let(:profile) { Kiosk::Redteam::Profile.new(pow_difficulty: 20) }

    context "when the server 404s every path (no register endpoint at all)" do
      it "returns blocked: false with a CONTROL FAILED detail" do
        register_returns(refused(404, "error" => { "code" => "not_found" }))

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
      end
    end

    context "when the solved control registration is refused" do
      it "returns blocked: false — the endpoint never issues, so nothing was proved" do
        register_returns(refused(422), refused(400), refused(503))

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
        expect(verdict.status).to eq(503)
      end
    end

    context "when the control answers 201 but hands back no access_token" do
      it "returns blocked: false" do
        register_returns(refused(422), refused(400),
                         { status: 201, body: JSON.generate("agent_id" => "a1"),
                           headers: { "Content-Type" => "application/json" } })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
      end
    end

    # A 5xx refuses the attempt by accident and would go on refusing it with the
    # PoW check deleted — so it is not a rejection by a gate.
    [500, 502, 503].each do |status|
      it "returns blocked: false when the pow: :skip attempt crashes #{status}" do
        register_returns(refused(status, "error" => "boom"), refused(400), issued)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("crashed")
        expect(verdict.detail).to include("a crash is not a gate")
      end
    end

    it "returns blocked: false when the pow: \"0\" attempt crashes 500" do
      register_returns(refused(422), refused(500, "error" => "boom"), issued)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('pow: "0" crashed')
    end

    it "does not spend a control solve when an attempt already succeeded" do
      stub = register_returns(issued("bad"), issued("bad2"))

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(stub).to have_been_requested.twice
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
