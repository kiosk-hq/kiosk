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

  describe "#call — non-vacuity" do
    context "when B can use A's resource after paying for it (broken — C2 BREACH)" do
      it "returns blocked: false" do
        # A registers, B registers
        stub_registers("a", "b")
        # A create_owned (reserve) succeeds
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "id" => "res-a" } }),
                     headers: { "Content-Type" => "application/json" })
        # B pays (no ownership check at pay time)
        stub_exec_pay(status: 200)
        # B starts A's rental — SHOULD be blocked but server allows it (breach)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "rental_token" => "tok-b" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("C2")
      end
    end

    context "when the server blocks B's gated action on A's resource (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "id" => "res-a" } }),
                     headers: { "Content-Type" => "application/json" })
        stub_exec_pay(status: 200)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 403,
                     body:   JSON.generate({ "error" => { "code" => "forbidden" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end

    context "when the server blocks B's payment itself (early ownership gate — also BLOCKED)" do
      it "returns blocked: true with early-gate detail" do
        stub_registers("a", "b")
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(status: 200,
                     body:   JSON.generate({ "value" => { "id" => "res-a" } }),
                     headers: { "Content-Type" => "application/json" })
        stub_exec_pay(status: 403)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.detail).to include("early")
      end
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
