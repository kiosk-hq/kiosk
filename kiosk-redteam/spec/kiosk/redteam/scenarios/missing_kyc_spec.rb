# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::MissingKyc do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      requires_kyc: true,
      gated_action: "start_rental",
      gated_args:   ->(ref) { { reservation_id: ref[:id] } },
      pay_for:      pay_for_callable,
    )
  end

  describe "#call — non-vacuity" do
    context "when the server allows gated action without KYC (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        # reserve, pay, start_rental all return 200 — no KYC gate
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_pay(status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
      end
    end

    context "when the server blocks the gated action (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req|
            body = JSON.parse(req.body)
            body["command"] == "run" && body.dig("body", "name") == "reserve"
          }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "id" => "res-1" } }),
                     headers: { "Content-Type" => "application/json" })
        stub_exec_pay(status: 200)
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req|
            body = JSON.parse(req.body)
            body["command"] == "run" && body.dig("body", "name") == "start_rental"
          }
          .to_return(status: 403,
                     body:   JSON.generate({ "error" => { "code" => "forbidden" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end
  end

  describe "#call — skip conditions" do
    it "skips when requires_kyc is false" do
      p = minimal_profile(gated_action: "start_rental", pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when gated_action is nil" do
      p = minimal_profile(requires_kyc: true, pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when pay_for is nil" do
      p = minimal_profile(requires_kyc: true, gated_action: "start_rental")
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
