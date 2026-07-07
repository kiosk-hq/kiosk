# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::MandateReplay do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(pay_for: pay_for_callable)
  end

  it "uses the public Client#pay_raw method (no private __send__ access)" do
    # Verify that the scenario never needs to reach into client internals.
    expect(client).not_to receive(:__send__)
    stub_registers("a", "b")
    stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
    stub_exec_pay(status: 403)
    scenario.call(client, profile)
  end

  describe "#call — non-vacuity" do
    context "when the server accepts a replayed mandate (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        # Both A's original pay AND B's replay succeed — server has no replay guard.
        stub_exec_pay(status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context "when the server rejects the replay (correct — BLOCKED)" do
      it "returns blocked: true on the second pay" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        # A's first pay succeeds; B's replay is rejected.
        stub_request(:post, "#{BASE_URL}/kiosk/pay")
          .to_return(
            { status: 200, body: JSON.generate({ "value" => { "payment_mandate_id" => "pm-1" } }),
              headers: { "Content-Type" => "application/json" } },
            { status: 403, body: JSON.generate({ "error" => { "code" => "forbidden" } }),
              headers: { "Content-Type" => "application/json" } },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(403)
      end
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
