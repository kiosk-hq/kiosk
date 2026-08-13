# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::MandatePrincipalSwap do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(pay_for: pay_for_callable)
  end

  describe "#call — non-vacuity" do
    context "when the server accepts a cross-principal mandate (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_pay(status: 200)  # server accepts the swapped mandate

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context "when the server rejects the cross-principal mandate (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_pay(status: 403)  # server rejects on principal mismatch

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end
  end

  # ── K-728 ────────────────────────────────────────────────────────────────
  #
  # Mandate verification is authorization: the claimed principal is not the
  # signer. A 402 means the instrument was declined before the mandates were
  # verified at all — the swap unexamined — and a 401 means B's own token was
  # rejected. Both used to score BLOCKED.
  describe "#call — only a 403 forbidden/rls_denied proves the binding was checked (K-728)" do
    def stub_pay(status, body)
      stub_registers("a", "b")
      stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .to_return(status: status, body: JSON.generate(body),
                   headers: { "Content-Type" => "application/json" })
    end

    it "blocks on 403 rls_denied" do
      stub_pay(403, "error" => { "code" => "rls_denied" })
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    it "does not block on a 402 decline" do
      stub_pay(402, "error" => { "code" => "payment_failed" })
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want status 403")
    end

    it "does not block on a 401" do
      stub_pay(401, "error" => { "code" => "unauthenticated" })
      expect(scenario.call(client, profile).blocked).to be(false)
    end

    it "does not block on a 403 carrying an unrelated code" do
      stub_pay(403, "error" => { "code" => "kyc_required" })
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want error.code")
    end

    it "does not block on a 500" do
      stub_pay(500, "error" => { "code" => "forbidden" })
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
