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
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "id" => "res-1" } }),
                     headers: { "Content-Type" => "application/json" })
        stub_exec_pay(status: 200)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 403,
                     body:   JSON.generate({ "error" => { "code" => "forbidden" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end
  end

  # ── K-731 ────────────────────────────────────────────────────────────────
  #
  # The pay response was discarded, so the payment gate could answer for the
  # KYC gate. Demonstrated: pay → 402, gated action → 402, printed
  # "BLOCKED ✓ MissingKyc" — a line the KYC gate's deletion would not change.
  describe "#call — the staged payment must actually settle (K-731)" do
    def stub_reserve_then_gated(gated_status:, gated_body: { "error" => { "code" => "forbidden" } })
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "reserve" }
        .to_return(status: 200, body: JSON.generate("value" => { "id" => "res-1" }),
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
        .to_return(status: gated_status, body: JSON.generate(gated_body),
                   headers: { "Content-Type" => "application/json" })
    end

    it "reports SETUP FAILED when pay is refused 402 and the gated action then 402s" do
      stub_registers("a")
      stub_reserve_then_gated(gated_status: 402, gated_body: { "error" => { "code" => "payment_setup_required" } })
      stub_exec_pay(status: 402)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.status).to eq(402)
      expect(verdict.detail).to include("SETUP FAILED")
      expect(verdict.detail).to include("payment gate")
    end

    it "reports SETUP FAILED when pay 403s, even though the gated action 403s too" do
      stub_registers("a")
      stub_reserve_then_gated(gated_status: 403)
      stub_exec_pay(status: 403)

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SETUP FAILED")
    end

    it "reports SETUP FAILED when pay crashes 500" do
      stub_registers("a")
      stub_reserve_then_gated(gated_status: 403)
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .to_return(status: 500, body: JSON.generate("error" => "boom"),
                   headers: { "Content-Type" => "application/json" })

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SETUP FAILED")
    end

    it "still scores BLOCKED when the payment settles and the KYC gate refuses" do
      stub_registers("a")
      stub_reserve_then_gated(gated_status: 403, gated_body: { "error" => { "code" => "kyc_required" } })
      stub_exec_pay(status: 200)

      expect(scenario.call(client, profile).blocked).to be(true)
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
