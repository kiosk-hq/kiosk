# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Kiosk::Redteam::Battery do
  let(:io)      { StringIO.new }
  let(:battery) { described_class.new(io: io) }
  let(:output)  { io.string }

  def scenario_double(name, verdict)
    instance_double(Kiosk::Redteam::Scenario, name: name).tap do |s|
      allow(s).to receive(:call).and_return(verdict)
    end
  end

  def blocked_verdict(status: 403)  = Kiosk::Redteam::Verdict.new(blocked: true,  skipped: false, status: status, detail: "")
  def breach_verdict(detail: "200") = Kiosk::Redteam::Verdict.new(blocked: false, skipped: false, status: 200, detail: detail)
  def skip_verdict(reason: "no per_user_query")
    Kiosk::Redteam::Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
  end

  describe "#record" do
    it "files and prints a blocked beat" do
      battery.record("CrossTenantRead", true, "Bob's rows exclude Alice's")

      expect(battery.blocked.map(&:name)).to eq(%w[CrossTenantRead])
      expect(output).to include("BLOCKED ✓ CrossTenantRead — Bob's rows exclude Alice's")
    end

    it "files and prints a breach" do
      battery.record("CrossOwnerEdit", false, "Bob edit Alice's listing → 200 (want 403)")

      expect(battery.breaches.map(&:name)).to eq(%w[CrossOwnerEdit])
      expect(output).to include("BREACH  ✗ CrossOwnerEdit — Bob edit Alice's listing → 200 (want 403)")
    end
  end

  describe "#scenario" do
    it "runs a library scenario and files its verdict beside the hand-written beats" do
      battery.record("HandWritten", true, "")
      battery.scenario(scenario_double("TokenTampering", blocked_verdict(status: 401)),
                       client: :client, profile: :profile)

      expect(battery.blocked.map(&:name)).to eq(%w[HandWritten TokenTampering])
      expect(output).to include("BLOCKED ✓ TokenTampering — HTTP 401")
    end

    it "files a skip as the third state by default" do
      battery.scenario(scenario_double("MissingKyc", skip_verdict(reason: "no kyc_valid")),
                       client: :client, profile: :profile)

      expect(battery.skipped.map(&:name)).to eq(%w[MissingKyc])
      expect(battery.breaches).to be_empty
      expect(output).to include("SKIP    — MissingKyc (no kyc_valid)")
    end

    # An origin that HAS the surface must not be allowed to record "could not
    # test" as a quiet third state: that is a defect of the harness, not a
    # property of the provider.
    it "files a skip as a breach when the caller says this origin must never skip it" do
      battery.scenario(scenario_double("DeviceGrantRoleSelfSelection", skip_verdict(reason: "no declared role")),
                       client: :client, profile: :profile, on_skip: :breach)

      expect(battery.breaches.map(&:name)).to eq(%w[DeviceGrantRoleSelfSelection])
      expect(output).to include("SKIPPED, which this origin must never do — no declared role")
    end
  end

  describe "#absorb" do
    let(:results) do
      [{ scenario: scenario_double("CrossTenantRead", blocked_verdict), verdict: blocked_verdict },
       { scenario: scenario_double("MissingKyc", skip_verdict), verdict: skip_verdict },
       { scenario: scenario_double("ForgedUserId", breach_verdict), verdict: breach_verdict(detail: "row is A's") }]
    end

    it "files a whole Runner battery into the same ledger" do
      battery.absorb(results)

      expect(battery.blocked.map(&:name)).to eq(%w[CrossTenantRead])
      expect(battery.skipped.map(&:name)).to eq(%w[MissingKyc])
      expect(battery.breaches.map(&:name)).to eq(%w[ForgedUserId])
    end

    # Runner#run already printed a line per scenario as it went.
    it "does not print again by default" do
      battery.absorb(results)

      expect(output).to eq("")
    end
  end

  describe "#report!" do
    it "answers 0 and says so when every attack that ran was blocked" do
      battery.record("A", true, "")
      battery.record("B", true, "")

      expect(battery.report!).to eq(0)
      expect(output).to include("2 BLOCKED, 0 SKIPPED, 0 BREACH — all attacks blocked.")
    end

    it "answers 1 and names the breach" do
      battery.record("A", true, "")
      battery.record("B", false, "settled at 200")

      expect(battery.report!).to eq(1)
      expect(output).to include("1 BLOCKED, 0 SKIPPED, 1 BREACH — FIX REQUIRED")
      expect(output).to include("BREACH  ✗ B — settled at 200")
    end

    # The floor. "No breaches" is satisfied by a battery in which nothing
    # happened, and a run that proved nothing must never read as green.
    it "answers 1 for a run with no proofs at all, though it has no breaches" do
      battery.scenario(scenario_double("MissingKyc", skip_verdict), client: :c, profile: :p)

      expect(battery.breaches).to be_empty
      expect(battery.report!(expected_skips: %w[MissingKyc])).to eq(1)
      expect(output).to include("proved NOTHING")
    end

    it "answers 1 for a battery that recorded nothing whatsoever" do
      expect(battery.report!).to eq(1)
    end

    it "answers 0 when the skips are the ones this provider is expected to skip" do
      battery.record("A", true, "")
      battery.scenario(scenario_double("MissingKyc", skip_verdict), client: :c, profile: :p)

      expect(battery.report!(expected_skips: %w[MissingKyc])).to eq(0)
    end

    it "answers 2 on an unexpected skip — a gate that silently stopped being tested" do
      battery.record("A", true, "")
      battery.scenario(scenario_double("MissingKyc", skip_verdict), client: :c, profile: :p)

      expect(battery.report!(expected_skips: [])).to eq(2)
      expect(output).to include("EXPECTED-APPLICABLE ASSERTION FAILED")
      expect(output).to include("Actual skips:   [\"MissingKyc\"]")
    end

    it "answers 2 when an expected skip did NOT happen — the list has gone stale" do
      battery.record("A", true, "")

      expect(battery.report!(expected_skips: %w[MissingKyc])).to eq(2)
      expect(output).to include("Expected skips: [\"MissingKyc\"]")
    end

    # A breach outranks a stale skip list: the operator must be sent to the
    # hole, not to the manifest.
    it "keeps the breach status when the skip set is also wrong" do
      battery.record("A", true, "")
      battery.record("B", false, "settled")
      battery.scenario(scenario_double("MissingKyc", skip_verdict), client: :c, profile: :p)

      expect(battery.report!(expected_skips: [])).to eq(1)
    end

    it "prints a machine-readable line last, carrying the status it answered" do
      battery.record("A", true, "")
      battery.record("B", false, "settled")
      status = battery.report!

      json = JSON.parse(output.lines.grep(/^\{/).last)
      expect(json).to eq("scenarios" => 2, "blocked" => 1, "skipped" => [],
                         "breaches" => %w[B], "exit" => status)
    end
  end
end
