# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::ForgedKyc do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      requires_kyc: true,
      gated_action: "start_rental",
      gated_args:   ->(ref) { { reservation_id: ref[:id] } },
      pay_for:      pay_for_callable,
      kyc_forged:   ->(_user_id) { "forged.wrong.issuer" },
    )
  end

  describe "#call — non-vacuity" do
    context "when the server rejects the forged KYC at /kyc (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_kyc(status: 403)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end

    context "when the server accepts forged KYC everywhere (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        stub_kyc(status: 200)
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_pay(status: 200)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "rental_token" => "tok" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
      end
    end
  end

  # ── K-736 ────────────────────────────────────────────────────────────────
  #
  # A metered /kyc answers 402 before the issuer/signature is examined, so the
  # forgery was neither caught nor accepted. Counting it as a block (the old
  # behaviour) and falling through to the gated action (the naive fix) are both
  # wrong; the second would attack with an un-attested principal.
  describe "#call — a 402 at /kyc is not a pass and does not fall through (K-736)" do
    %w[pow_required payment_setup_required payment_failed].each do |code|
      it "reports could-not-test on 402 #{code}" do
        stub_registers("a")
        stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
          .to_return(status: 402, body: JSON.generate("error" => { "code" => code }),
                     headers: { "Content-Type" => "application/json" })
        run_stub = stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(402)
        expect(verdict.detail).to include("COULD NOT TEST")
        expect(verdict.detail).to include(code.inspect)
        expect(verdict.detail).to include("the forged attestation this scenario submits to /kyc")
        expect(run_stub).not_to have_been_requested
      end
    end
  end

  describe "#call — skip conditions" do
    it "skips when requires_kyc is false" do
      p = minimal_profile(gated_action: "start_rental", pay_for: pay_for_callable,
                          kyc_forged: ->(_uid) { "x" })
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when kyc_forged is nil" do
      p = minimal_profile(requires_kyc: true, gated_action: "start_rental", pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
