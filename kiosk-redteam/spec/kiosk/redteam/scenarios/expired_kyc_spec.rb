# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::ExpiredKyc do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      requires_kyc: true,
      gated_action: "start_rental",
      gated_args:   ->(ref) { { reservation_id: ref[:id] } },
      pay_for:      pay_for_callable,
      kyc_expired:  ->(_user_id) { "expired.jws.token" },
    )
  end

  describe "#call — non-vacuity" do
    context "when the server rejects the expired KYC at the kyc endpoint (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_kyc(status: 403)  # /kyc rejects expired attestation

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end

    context "when the server accepts expired KYC and also accepts gated action (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        stub_kyc(status: 200)  # /kyc accepts expired attestation
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_pay(status: 200)
        # Gated action also succeeds — no gate catches the expired KYC
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "rental_token" => "tok" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
      end
    end

    context "when expired KYC passes /kyc but gated action is blocked (also correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_kyc(status: 200)  # /kyc accepts (lenient)
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
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

  describe "#call — skip conditions" do
    it "skips when requires_kyc is false" do
      p = minimal_profile(gated_action: "start_rental", pay_for: pay_for_callable,
                          kyc_expired: ->(_uid) { "x" })
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when kyc_expired is nil" do
      p = minimal_profile(requires_kyc: true, gated_action: "start_rental", pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
