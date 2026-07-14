# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::UnpaidGatedAction do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      gated_action: "start_rental",
      gated_args:   ->(ref) { { reservation_id: ref[:id] } },
    )
  end

  describe "#call — non-vacuity" do
    context "when the server allows the gated action without payment (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a")
        # create_owned (reserve) + gated_action (start_rental) both return 200
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context "when the server blocks the gated action (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a")
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(status: 200,
                     body: JSON.generate({ "value" => { "id" => "res-1" } }),
                     headers: { "Content-Type" => "application/json" })
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
          .to_return(status: 403,
                     body: JSON.generate({ "error" => { "code" => "forbidden" } }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end
  end

  # Coverage for submit_valid_kyc + the `if profile.requires_kyc` guard (K-296).
  # The three scenarios that gate submit_valid_kyc behind requires_kyc
  # (UnpaidGatedAction, PayForOtherUseSelf, SpentResourceReuse) all build their
  # profile with requires_kyc defaulting to false, so the helper never ran in
  # the gem suite though it is live via the skooti demo. This exercises the
  # requires_kyc:true + kyc_valid path so the helper POSTs a valid attestation.
  describe "#call — requires_kyc:true drives submit_valid_kyc" do
    let(:kyc_profile) do
      minimal_profile(
        gated_action: "start_rental",
        gated_args:   ->(ref) { { reservation_id: ref[:id] } },
        requires_kyc: true,
        kyc_valid:    ->(user_id) { "valid-kyc-jws-for-#{user_id}" },
      )
    end

    it "submits the kyc_valid attestation for the registered principal" do
      stub_registers("a")
      stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
      kyc_stub = stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
        .with { |req| JSON.parse(req.body)["kyc_jws"] == "valid-kyc-jws-for-user-a" }
        .to_return(status: 200,
                   body: JSON.generate({ "ok" => true }),
                   headers: { "Content-Type" => "application/json" })

      scenario.call(client, kyc_profile)

      # submit_valid_kyc ran: it called profile.kyc_valid with principal.user_id
      # and POSTed the resulting JWS to /kiosk/agents/kyc.
      expect(kyc_stub).to have_been_requested.once
    end
  end

  describe "#call — skip conditions" do
    it "skips when gated_action is nil" do
      p = minimal_profile
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when create_owned is nil" do
      p = Kiosk::Redteam::Profile.new(gated_action: "start_rental")
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
