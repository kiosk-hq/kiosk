# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::PayForOtherUseSelf do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      gated_action: "start_rental",
      gated_args:   ->(ref) { { reservation_id: ref[:id] } },
      pay_for:      pay_for_callable,
    )
  end

  # The wire traffic is register ×2 → POST /kiosk/pay (B) → POST
  # /kiosk/start_rental (B, on A's resource). minimal_profile's create_owned is
  # a plain lambda, so A's resource costs no request.
  RENTAL_BODY = { "scooter_code" => "SK-001", "rental_token" => "rt-b",
                  "exp" => 4_102_444_800 }.freeze

  describe "#call — non-vacuity" do
    context "when B can use A's resource after paying for it (broken — C2 BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        stub_pay(status: 200)                       # no ownership check at pay time
        # B starts A's rental — SHOULD be blocked but server allows it (breach)
        stub_action("start_rental", status: 200, body: RENTAL_BODY)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("C2")
      end
    end

    context "when the server blocks B's gated action on A's resource (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_pay(status: 200)
        stub_action("start_rental", status: 403, code: "forbidden")

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end

    context "when the server blocks B's payment itself (early ownership gate — also BLOCKED)" do
      it "returns blocked: true with early-gate detail" do
        stub_registers("a", "b")
        stub_pay(status: 403, code: "forbidden")

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.detail).to include("early")
      end
    end

    it "attacks with B's bearer token on A's resource id" do
      stub_registers("a", "b")
      stub_pay(status: 200)
      captured = nil
      stub_request(:post, verb_url("start_rental"))
        .with { |req| captured = req; true }
        .to_return(problem_return("forbidden"))

      scenario.call(client, profile)

      expect(captured.headers["Authorization"]).to eq("Bearer tok-b")
      expect(JSON.parse(captured.body)).to eq("reservation_id" => "res-1")
    end
  end

  # ── K-732 ────────────────────────────────────────────────────────────────
  #
  # ANY blocked? at the pay step returned "blocked at pay step (early ownership
  # check)" and the attack was never attempted — so a card decline and an
  # expired token were both reported as the ownership gate firing.
  describe "#call — only a 403 at pay time is the early ownership gate (K-732)" do
    it "scores the 403 forbidden pay refusal as the early ownership gate" do
      stub_registers("a", "b")
      stub_pay(status: 403, code: "forbidden")

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(true)
      expect(verdict.detail).to include("early ownership check")
    end

    it "accepts rls_denied as the same gate enforced in the database" do
      stub_registers("a", "b")
      stub_pay(status: 403, code: "rls_denied")

      expect(scenario.call(client, profile).blocked).to be(true)
    end

    it "does NOT score a 402 payment decline as the ownership gate" do
      stub_registers("a", "b")
      gated = stub_action("start_rental", status: 200, body: RENTAL_BODY)
      stub_pay(status: 402, code: "payment_failed")

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.status).to eq(402)
      expect(verdict.detail).to include("SETUP FAILED")
      expect(gated).not_to have_been_requested
    end

    it "does NOT score a 401 expired token as the ownership gate" do
      stub_registers("a", "b")
      stub_pay(status: 401, code: "unauthenticated")

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SETUP FAILED")
    end

    it "does NOT score a 403 from an unrelated code (kyc_required) as the ownership gate" do
      stub_registers("a", "b")
      stub_pay(status: 403, code: "kyc_required")

      expect(scenario.call(client, profile).blocked).to be(false)
    end

    it "does NOT score a 500 at pay time as anything but a failure" do
      stub_registers("a", "b")
      stub_pay(status: 500, code: "internal_error")

      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  # The use-time verdict names the ownership gate too.
  describe "#call — the use-time refusal must be the ownership gate (K-732)" do
    def stub_flow(gated_status:, gated_code: nil, gated_body: nil)
      stub_registers("a", "b")
      stub_pay(status: 200)
      stub_action("start_rental", status: gated_status, code: gated_code, body: gated_body)
    end

    it "blocks on 403 rls_denied" do
      stub_flow(gated_status: 403, gated_code: "rls_denied")
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    # B paid; a payment gate answering here is a different bug, not this one.
    it "does not block on a 402 at use time" do
      stub_flow(gated_status: 402, gated_code: "payment_setup_required")
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want status 403")
    end

    it "does not block on a 403 kyc_required at use time" do
      stub_flow(gated_status: 403, gated_code: "kyc_required")
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want error.code")
    end

    it "does not block on a 401 at use time" do
      stub_flow(gated_status: 401, gated_code: "unauthenticated")
      expect(scenario.call(client, profile).blocked).to be(false)
    end

    it "does not block on a 500 at use time" do
      stub_flow(gated_status: 500, gated_code: "forbidden")
      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  # K-731 at a fifth call site: B's staged attestation was discarded too.
  describe "#call — B's staged KYC must be accepted (K-731)" do
    let(:kyc_profile) do
      minimal_profile(
        gated_action: "start_rental",
        gated_args:   ->(ref) { { reservation_id: ref[:id] } },
        pay_for:      pay_for_callable,
        requires_kyc: true,
        kyc_valid:    ->(user_id) { "valid-kyc-jws-for-#{user_id}" },
      )
    end

    it "reports SETUP FAILED when B's attestation is refused" do
      stub_registers("a", "b")
      stub_kyc(status: 403, code: "forbidden")

      verdict = scenario.call(client, kyc_profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SETUP FAILED")
      expect(verdict.detail).to include("ownership gate")
    end
  end

  describe "#call — skip conditions" do
    it "skips when gated_action is nil" do
      p = minimal_profile(pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when pay_for is nil" do
      p = minimal_profile(gated_action: "start_rental")
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when create_owned is nil" do
      p = Kiosk::Redteam::Profile.new(gated_action: "start_rental", pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
