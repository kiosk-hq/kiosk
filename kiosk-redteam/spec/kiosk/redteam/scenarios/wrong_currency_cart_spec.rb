# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::WrongCurrencyCart do
  subject(:scenario) { described_class.new }

  let(:client)  { Kiosk::Redteam::Client.new(base_url: BASE_URL) }
  let(:profile) { minimal_profile(currency: "eur", pay_for: pay_for_callable) }

  describe "#call — non-vacuity" do
    context "when the operator settles a cart in a currency it does not price in (BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        stub_pay(status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include("usd cart settled at a EUR operator")
      end
    end

    context "when the operator refuses it" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_pay(status: 403, code: "forbidden")

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end
    end

    # A crash is not a cashier check. The operator that 500s on a foreign
    # currency has not refused it — it has fallen over on the way to deciding.
    it "does not score a 500 as a refusal" do
      stub_registers("a")
      stub_pay(status: 500, code: "internal_error")

      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  describe "the probed currency" do
    it "denominates both mandates in a currency that is NOT the operator's" do
      stub_registers("a")
      captured = nil
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .with { |req| captured = JSON.parse(req.body); true }
        .to_return(wire_return(status: 403, code: "forbidden"))

      scenario.call(client, profile)

      expect(captured).not_to be_nil
      intent = JWT.decode(captured.fetch("intent_mandate_jws"), nil, false).first
      cart   = JWT.decode(captured.fetch("cart_mandate_jws"), nil, false).first
      expect(intent["currency"]).to eq("usd")
      expect(cart["currency"]).to eq("usd")
    end

    # An operator that prices in dollars must not be probed with dollars: the
    # cart would never have been foreign, and BLOCKED would be printed for an
    # attack that did not happen.
    it "picks a different currency for a dollar-priced operator" do
      stub_registers("a")
      captured = nil
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .with { |req| captured = JSON.parse(req.body); true }
        .to_return(wire_return(status: 403, code: "forbidden"))

      usd = minimal_profile(currency: "usd", pay_for: pay_for_callable)
      verdict = scenario.call(client, usd)

      cart = JWT.decode(captured.fetch("cart_mandate_jws"), nil, false).first
      expect(cart["currency"]).to eq("eur")
      expect(verdict.detail).to be_a(String)
    end
  end

  describe "#call — skips" do
    it "skips when the profile names no currency" do
      verdict = scenario.call(client, minimal_profile(pay_for: pay_for_callable))

      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("no currency")
    end

    it "skips when the profile cannot build a mandate pair" do
      verdict = scenario.call(client, minimal_profile(currency: "eur"))

      expect(verdict.skipped).to be(true)
      expect(verdict.detail).to include("no pay_for")
    end

    it "skips when the profile cannot create an owned resource" do
      no_owner = Kiosk::Redteam::Profile.new(currency: "eur", pay_for: pay_for_callable)

      verdict = scenario.call(client, no_owner)

      expect(verdict.skipped).to be(true)
      expect(verdict.detail).to include("no create_owned")
    end
  end
end
