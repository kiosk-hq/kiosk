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
