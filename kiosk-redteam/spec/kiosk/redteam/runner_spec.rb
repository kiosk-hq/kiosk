# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Redteam::Runner do
  let(:base_url) { "http://kiosk.example.com" }
  let(:profile)  { double("Profile") }

  def make_scenario(name, verdict)
    scenario = instance_double(Kiosk::Redteam::Scenario, name:)
    allow(scenario).to receive(:call).and_return(verdict)
    scenario
  end

  def blocked_verdict(status: 403)
    Kiosk::Redteam::Verdict.new(blocked: true, status:, detail: "")
  end

  def breach_verdict(detail: "attack worked", status: 200)
    Kiosk::Redteam::Verdict.new(blocked: false, status:, detail:)
  end

  # ── #run ────────────────────────────────────────────────────────────────

  describe "#run" do
    it "returns an array of { scenario:, verdict: } hashes" do
      s1 = make_scenario("CrossTenantRead", blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      results = runner.run([s1])
      expect(results.length).to eq(1)
      expect(results.first[:scenario]).to be(s1)
      expect(results.first[:verdict]).to be_a(Kiosk::Redteam::Verdict)
    end

    it "runs multiple scenarios in order" do
      call_order = []
      s1 = make_scenario("S1", blocked_verdict)
      s2 = make_scenario("S2", blocked_verdict)
      allow(s1).to receive(:call) { call_order << "S1"; blocked_verdict }
      allow(s2).to receive(:call) { call_order << "S2"; blocked_verdict }

      described_class.new(base_url:, profile:).run([s1, s2])
      expect(call_order).to eq(%w[S1 S2])
    end

    it "prints BLOCKED for a blocked verdict" do
      s = make_scenario("ForgedUserId", blocked_verdict(status: 403))
      expect { described_class.new(base_url:, profile:).run([s]) }.to output(/BLOCKED.*ForgedUserId/).to_stdout
    end

    it "prints BREACH for an unblocked verdict and includes the detail" do
      s = make_scenario("MandateSwap", breach_verdict(detail: "200 — data returned"))
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.to output(/BREACH.*MandateSwap.*200 — data returned/).to_stdout
    end

    it "passes the client (not nil) and the profile to each scenario" do
      s = instance_double(Kiosk::Redteam::Scenario, name: "Probe")
      expect(s).to receive(:call) do |client, passed_profile|
        expect(client).to be_a(Kiosk::Redteam::Client)
        expect(passed_profile).to be(profile)
        blocked_verdict
      end
      described_class.new(base_url:, profile:).run([s])
    end
  end

  # ── #all_blocked? ────────────────────────────────────────────────────────

  describe "#all_blocked?" do
    it "returns false before any run" do
      runner = described_class.new(base_url:, profile:)
      expect(runner.all_blocked?).to be(false)
    end

    it "returns true when all scenarios are blocked" do
      s1 = make_scenario("A", blocked_verdict(status: 401))
      s2 = make_scenario("B", blocked_verdict(status: 403))
      runner = described_class.new(base_url:, profile:)
      runner.run([s1, s2])
      expect(runner.all_blocked?).to be(true)
    end

    it "returns false if any scenario is not blocked" do
      s1 = make_scenario("A", blocked_verdict)
      s2 = make_scenario("B", breach_verdict(detail: "breach!"))
      runner = described_class.new(base_url:, profile:)
      runner.run([s1, s2])
      expect(runner.all_blocked?).to be(false)
    end

    it "returns false when only the breach scenario runs" do
      s = make_scenario("C2PayForOtherUseSelf", breach_verdict(status: 200, detail: "rental started"))
      runner = described_class.new(base_url:, profile:)
      runner.run([s])
      expect(runner.all_blocked?).to be(false)
    end

    # Guard: a 500 response fed through blocked?(false) must also fail all_blocked?
    it "returns false when a verdict wraps a 500 (crash-masquerade guard)" do
      # The Scenario level would call Redteam.blocked?(response) with status 500
      # and get false, yielding a breach verdict.
      crash_verdict = Kiosk::Redteam::Verdict.new(blocked: false, status: 500, detail: "server crashed")
      s = make_scenario("SomeCrash", crash_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s])
      expect(runner.all_blocked?).to be(false)
    end
  end
end
