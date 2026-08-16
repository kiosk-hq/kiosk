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

  # ── K-736 ────────────────────────────────────────────────────────────────
  #
  # The tolled-verb case, demonstrated on a stub transport before the fix: the
  # gated action answered 402 and the runner printed
  # "BLOCKED ✓ UnpaidGatedAction (HTTP 402)" with all_blocked? true — a pass for
  # an attack that never executed, because #run has no 402 retry (the harness
  # solves PoW only in Client#register_raw). Latent in the shipped demos, which
  # answer 403 here; armed the day an operator prices a real verb.
  describe "#call — a 402 on the gated action is not a pass (K-736)" do
    def stub_toll(code)
      stub_registers("a")
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "reserve" }
        .to_return(status: 200, body: JSON.generate("value" => { "id" => "res-1" }),
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
        .to_return(status: 402, body: JSON.generate("error" => { "code" => code }),
                   headers: { "Content-Type" => "application/json" })
    end

    %w[pow_required payment_setup_required payment_failed].each do |code|
      it "does not block on 402 #{code}, and names it" do
        stub_toll(code)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(402)
        expect(verdict.detail).to include("COULD NOT TEST")
        expect(verdict.detail).to include(code.inspect)
      end
    end

    it "keeps the battery from going green on it" do
      stub_toll("pow_required")
      runner = Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile: profile)
      runner.run([scenario])

      expect(runner.all_blocked?).to be(false)
      expect(runner.breaches.size).to eq(1)
    end
  end

  # Coverage for submit_valid_kyc + the `if profile.requires_kyc` guard.
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

  # ── K-731 ────────────────────────────────────────────────────────────────
  #
  # The staged KYC is the ONLY thing separating this scenario from MissingKyc.
  # Its response was discarded, so an attestation the provider refused left the
  # gated action to be denied for want of KYC — scored here as the payment gate.
  describe "#call — the staged KYC must be accepted (K-731)" do
    let(:kyc_profile) do
      minimal_profile(
        gated_action: "start_rental",
        gated_args:   ->(ref) { { reservation_id: ref[:id] } },
        requires_kyc: true,
        kyc_valid:    ->(user_id) { "valid-kyc-jws-for-#{user_id}" },
      )
    end

    [403, 401, 500].each do |status|
      it "reports SETUP FAILED when the valid attestation is refused #{status}" do
        stub_registers("a")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
          .to_return(status: status, body: JSON.generate("error" => { "code" => "forbidden" }),
                     headers: { "Content-Type" => "application/json" })

        verdict = scenario.call(client, kyc_profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(status)
        expect(verdict.detail).to include("SETUP FAILED")
        expect(verdict.detail).to include("KYC gate")
      end
    end

    it "does not run the gated action once the KYC setup has failed" do
      stub_registers("a")
      run_stub = stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
      stub_kyc(status: 403)

      scenario.call(client, kyc_profile)

      # create_owned is called AFTER the setup assertion, so no /run at all.
      expect(run_stub).not_to have_been_requested
    end

    it "proceeds normally when the attestation is accepted" do
      stub_registers("a")
      stub_kyc(status: 200)
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "reserve" }
        .to_return(status: 200, body: JSON.generate("value" => { "id" => "res-1" }),
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
        .to_return(status: 403, body: JSON.generate("error" => { "code" => "forbidden" }),
                   headers: { "Content-Type" => "application/json" })

      expect(scenario.call(client, kyc_profile).blocked).to be(true)
    end

    # A profile with no KYC surface has no setup step to assert.
    it "is unaffected when requires_kyc is false (no setup call to check)" do
      stub_registers("a")
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "reserve" }
        .to_return(status: 200, body: JSON.generate("value" => { "id" => "res-1" }),
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "start_rental" }
        .to_return(status: 403, body: JSON.generate("error" => { "code" => "forbidden" }),
                   headers: { "Content-Type" => "application/json" })

      expect(scenario.call(client, profile).blocked).to be(true)
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
