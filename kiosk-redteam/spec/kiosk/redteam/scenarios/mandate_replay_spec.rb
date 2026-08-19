# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::MandateReplay do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(pay_for: pay_for_callable)
  end

  # `POST /kiosk/pay` twice — A's legitimate settlement, then B's replay of A's
  # exact JWS under B's token — so the two legs are one stub answering in order.
  # minimal_profile's create_owned is a plain lambda and costs no request.

  it "uses the public Client#pay_raw method (no private __send__ access)" do
    # Verify that the scenario never needs to reach into client internals.
    expect(client).not_to receive(:__send__)
    stub_registers("a", "b")
    stub_pay(status: 403, code: "forbidden")
    scenario.call(client, profile)
  end

  describe "#call — non-vacuity" do
    context "when the server accepts a replayed mandate (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        # Both A's original pay AND B's replay succeed — server has no replay guard.
        stub_pay(status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context "when the server rejects the replay (correct — BLOCKED)" do
      it "returns blocked: true on the second pay" do
        stub_registers("a", "b")
        # A's first pay succeeds; B's replay is rejected.
        stub_request(:post, "#{BASE_URL}/kiosk/pay").to_return(
          json_return(200, PAY_OK),
          problem_return("forbidden"),
        )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(403)
      end
    end
  end

  # ── K-728 ────────────────────────────────────────────────────────────────
  #
  # The replay is refused because the mandate binds to its signer — a 403
  # forbidden/rls_denied. A 402 on the replay means it was never verified, only
  # unfunded; that used to score BLOCKED.
  describe "#call — only a 403 forbidden/rls_denied proves the binding was checked (K-728)" do
    def stub_replay(status, code)
      stub_registers("a", "b")
      stub_request(:post, "#{BASE_URL}/kiosk/pay").to_return(
        json_return(200, PAY_OK),
        problem_return(code, status: status),
      )
    end

    it "blocks on 403 rls_denied" do
      stub_replay(403, "rls_denied")
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    it "does not block when the replay is merely declined 402" do
      stub_replay(402, "payment_failed")
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want status 403")
    end

    it "does not block on a 401" do
      stub_replay(401, "unauthenticated")
      expect(scenario.call(client, profile).blocked).to be(false)
    end

    it "does not block on a 500" do
      stub_replay(500, "forbidden")
      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  describe "#call — skip conditions" do
    it "skips when pay_for is nil" do
      p = Kiosk::Redteam::Profile.new(create_owned: ->(_c, _pr) { { id: "x" } })
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when create_owned is nil" do
      p = Kiosk::Redteam::Profile.new(pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
