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
        stub_kyc(status: 403, code: "forbidden")  # /kyc rejects expired attestation

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end

    context "when the server accepts expired KYC and also accepts gated action (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        stub_kyc(status: 200)  # /kyc accepts expired attestation
        stub_pay(status: 200)
        # Gated action also succeeds — no gate catches the expired KYC
        stub_action("start_rental", status: 200,
                    body: { "scooter_code" => "SK-001", "rental_token" => "rt-1", "exp" => 4_102_444_800 })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
      end
    end

    context "when expired KYC passes /kyc but gated action is blocked (also correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_kyc(status: 200)  # /kyc accepts (lenient)
        stub_pay(status: 200)
        stub_action("start_rental", status: 403, code: "forbidden")

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end
  end

  # ── K-736 ────────────────────────────────────────────────────────────────
  #
  # A metered /kyc answers 402 before the attestation is examined. The old
  # `blocked?` counted that as "the expired attestation did not take effect";
  # simply dropping 402 from that set would be worse, since the scenario would
  # then walk on and attack the gated action with an UN-ATTESTED principal —
  # MissingKyc running under ExpiredKyc's name. It stalls instead.
  describe "#call — a 402 at /kyc is not a pass and does not fall through (K-736)" do
    %w[pow_required payment_setup_required payment_failed].each do |code|
      it "reports could-not-test on 402 #{code}" do
        stub_registers("a")
        stub_kyc(status: 402, code: code)
        pay_stub  = stub_pay(status: 200)
        gate_stub = stub_action("start_rental", status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(402)
        expect(verdict.detail).to include("COULD NOT TEST")
        expect(verdict.detail).to include(code.inspect)
        expect(verdict.detail).to include("the expired attestation this scenario submits to /kyc")
        # It must NOT proceed to stage the payment or run the gated action.
        expect(pay_stub).not_to have_been_requested
        expect(gate_stub).not_to have_been_requested
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
