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
    Kiosk::Redteam::Verdict.new(blocked: true, skipped: false, status:, detail: "")
  end

  def breach_verdict(detail: "attack worked", status: 200)
    Kiosk::Redteam::Verdict.new(blocked: false, skipped: false, status:, detail:)
  end

  def skip_verdict(reason: "no gated_action")
    Kiosk::Redteam::Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
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

    # K-728: "BLOCKED ✓ X" alone does not say which gate answered, so a run that
    # went green off an unrelated 404 reads exactly like one that proved the
    # gate. The status is part of the claim.
    it "prints the status on the BLOCKED line" do
      s = make_scenario("ForgedUserId", blocked_verdict(status: 403))
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.to output(/BLOCKED ✓ ForgedUserId \(HTTP 403\)/).to_stdout
    end

    it "prints the status a permissive verdict actually got, not a fixed one" do
      s = make_scenario("TokenTampering", blocked_verdict(status: 401))
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.to output(/BLOCKED ✓ TokenTampering \(HTTP 401\)/).to_stdout
    end

    it "prints BREACH for an unblocked verdict and includes the detail" do
      s = make_scenario("MandateSwap", breach_verdict(detail: "200 — data returned"))
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.to output(/BREACH.*MandateSwap.*200 — data returned/).to_stdout
    end

    it "prints SKIP (not BLOCKED) for a skipped verdict" do
      s = make_scenario("UnpaidGatedAction", skip_verdict(reason: "no gated_action"))
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.to output(/SKIP.*UnpaidGatedAction/).to_stdout
    end

    it "does not print BLOCKED for a skipped verdict" do
      s = make_scenario("UnpaidGatedAction", skip_verdict)
      expect {
        described_class.new(base_url:, profile:).run([s])
      }.not_to output(/BLOCKED/).to_stdout
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

  # ── the abort path ───────────────────────────────────────────────────────
  #
  # Every profile callable in the three consuming demos raises on a bad setup
  # step ("redteam: create_order failed (500)"), so the whole battery rests on
  # what a raising scenario does — and none of it was covered (K-728). It must
  # ABORT, loudly, and must never leave a caller able to read the run as clean.
  describe "a scenario that raises" do
    def raising_scenario(name, error = RuntimeError.new("redteam: create_owned failed (500)"))
      s = instance_double(Kiosk::Redteam::Scenario, name:)
      allow(s).to receive(:call).and_raise(error)
      s
    end

    it "propagates out of #run rather than scoring a verdict" do
      runner = described_class.new(base_url:, profile:)
      expect { runner.run([raising_scenario("CrossTenantRead")]) }
        .to raise_error(RuntimeError, /create_owned failed/)
    end

    it "does not run the scenarios queued after it" do
      later = make_scenario("Later", blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      expect { runner.run([raising_scenario("Boom"), later]) }.to raise_error(RuntimeError)
      expect(later).not_to have_received(:call)
    end

    it "leaves all_blocked? false — an aborted battery proved nothing" do
      runner = described_class.new(base_url:, profile:)
      suppress = ->(&blk) { begin; blk.call; rescue RuntimeError; end }
      suppress.call { runner.run([raising_scenario("Boom")]) }
      expect(runner.all_blocked?).to be(false)
    end

    # The reason the quick-start idiom had to change: `breaches` is EMPTY after
    # an abort (there are no results to reject), so `exit 1 if breaches.any?`
    # exits 0 on a battery that never ran. `unless all_blocked?` exits 1.
    it "leaves breaches empty, so only the all_blocked? idiom fails closed" do
      runner = described_class.new(base_url:, profile:)
      begin
        runner.run([raising_scenario("Boom")])
      rescue RuntimeError
        nil
      end
      expect(runner.breaches).to eq([])
      expect(runner.all_blocked?).to be(false)
    end

    it "aborts on a mid-battery raise even after earlier scenarios were blocked" do
      first  = make_scenario("First", blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      expect { runner.run([first, raising_scenario("Boom")]) }.to raise_error(RuntimeError)
      expect(runner.all_blocked?).to be(false)
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
      crash_verdict = Kiosk::Redteam::Verdict.new(blocked: false, skipped: false, status: 500, detail: "server crashed")
      s = make_scenario("SomeCrash", crash_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s])
      expect(runner.all_blocked?).to be(false)
    end

    # Critical: a skip must NOT count as a pass.
    it "returns true when the only non-skipped scenario is blocked (skip does not count as pass)" do
      s_blocked = make_scenario("A", blocked_verdict)
      s_skipped = make_scenario("B", skip_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s_blocked, s_skipped])
      expect(runner.all_blocked?).to be(true)
    end
  end

  # ── #breaches ───────────────────────────────────────────────────────────────

  describe "#breaches" do
    it "returns an empty array before any run" do
      runner = described_class.new(base_url:, profile:)
      expect(runner.breaches).to eq([])
    end

    it "returns an empty array when all scenarios are blocked" do
      s = make_scenario("A", blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s])
      expect(runner.breaches).to be_empty
    end

    it "returns an empty array when a scenario is skipped (skip is not a breach)" do
      s = make_scenario("B", skip_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s])
      expect(runner.breaches).to be_empty
    end

    it "returns only the breach results" do
      s_blocked = make_scenario("A", blocked_verdict)
      s_breach  = make_scenario("B", breach_verdict(detail: "data leaked"))
      s_skipped = make_scenario("C", skip_verdict)
      runner = described_class.new(base_url:, profile:)
      runner.run([s_blocked, s_breach, s_skipped])
      expect(runner.breaches.size).to eq(1)
      expect(runner.breaches.first[:scenario]).to be(s_breach)
    end
  end
end
