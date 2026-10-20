# frozen_string_literal: true

require 'spec_helper'

RSpec.shared_context 'with a profile double and scenario doubles' do
  let(:base_url) { 'http://kiosk.example.com' }

  let(:profile)  { instance_double(Kiosk::Redteam::Profile) }

  def make_scenario(name, verdict)
    scenario = instance_double(Kiosk::Redteam::Scenario, name:)
    allow(scenario).to receive(:call).and_return(verdict)
    scenario
  end

  def blocked_verdict(status: 403)
    Kiosk::Redteam::Verdict.new(blocked: true, skipped: false, status:, detail: '')
  end

  def breach_verdict(detail: 'attack worked', status: 200)
    Kiosk::Redteam::Verdict.new(blocked: false, skipped: false, status:, detail:)
  end

  def skip_verdict(reason: 'no gated_action')
    Kiosk::Redteam::Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
  end
end

RSpec.describe Kiosk::Redteam::Runner do
  # ── #run ────────────────────────────────────────────────────────────────

  describe '#run' do
    include_context 'with a profile double and scenario doubles'

    it 'returns an array of { scenario:, verdict: } hashes' do
      s1 = make_scenario('CrossTenantRead', blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      results = runner.run([s1])
      expect(results.length).to eq(1)
      expect(results.first[:scenario]).to be(s1)
      expect(results.first[:verdict]).to be_a(Kiosk::Redteam::Verdict)
    end

    it 'runs multiple scenarios in order' do
      call_order = []
      s1 = make_scenario('S1', blocked_verdict)
      s2 = make_scenario('S2', blocked_verdict)
      allow(s1).to receive(:call) {
        call_order << 'S1'
        blocked_verdict
      }
      allow(s2).to receive(:call) {
        call_order << 'S2'
        blocked_verdict
      }

      described_class.new(base_url:, profile:).run([s1, s2])
      expect(call_order).to eq(%w[S1 S2])
    end

    it 'prints BLOCKED for a blocked verdict' do
      s = make_scenario('ForgedUserId', blocked_verdict(status: 403))
      expect { described_class.new(base_url:, profile:).run([s]) }.to output(/BLOCKED.*ForgedUserId/).to_stdout
    end

    # K-728: "BLOCKED ✓ X" alone does not say which gate answered, so a run that
    # went green off an unrelated 404 reads exactly like one that proved the
    # gate. The status is part of the claim.
    it 'prints the status on the BLOCKED line' do
      s = make_scenario('ForgedUserId', blocked_verdict(status: 403))
      expect do
        described_class.new(base_url:, profile:).run([s])
      end.to output(/BLOCKED ✓ ForgedUserId \(HTTP 403\)/).to_stdout
    end

    it 'prints the status a permissive verdict actually got, not a fixed one' do
      s = make_scenario('TokenTampering', blocked_verdict(status: 401))
      expect do
        described_class.new(base_url:, profile:).run([s])
      end.to output(/BLOCKED ✓ TokenTampering \(HTTP 401\)/).to_stdout
    end

    it 'prints BREACH for an unblocked verdict and includes the detail' do
      s = make_scenario('MandateSwap', breach_verdict(detail: '200 — data returned'))
      expect do
        described_class.new(base_url:, profile:).run([s])
      end.to output(/BREACH.*MandateSwap.*200 — data returned/).to_stdout
    end

    it 'prints SKIP (not BLOCKED) for a skipped verdict' do
      s = make_scenario('UnpaidGatedAction', skip_verdict(reason: 'no gated_action'))
      expect do
        described_class.new(base_url:, profile:).run([s])
      end.to output(/SKIP.*UnpaidGatedAction/).to_stdout
    end

    it 'does not print BLOCKED for a skipped verdict' do
      s = make_scenario('UnpaidGatedAction', skip_verdict)
      expect do
        described_class.new(base_url:, profile:).run([s])
      end.not_to output(/BLOCKED/).to_stdout
    end

    it 'passes the client (not nil) and the profile to each scenario' do
      s = make_scenario('Probe', blocked_verdict)

      described_class.new(base_url:, profile:).run([s])

      expect(s).to have_received(:call) do |client, passed_profile|
        expect(client).to be_a(Kiosk::TestHelpers::Assistant)
        expect(passed_profile).to be(profile)
      end
    end
  end

  # ── the abort path ───────────────────────────────────────────────────────
  #
  # Every profile callable in the three consuming demos raises on a bad setup
  # step ("redteam: create_order failed (500)"), so the whole battery rests on
  # what a raising scenario does — and none of it was covered (K-728). It must
  # ABORT, loudly, and must never leave a caller able to read the run as clean.
  describe 'a scenario that raises' do
    include_context 'with a profile double and scenario doubles'

    def raising_scenario(name, error = RuntimeError.new('redteam: create_owned failed (500)'))
      s = instance_double(Kiosk::Redteam::Scenario, name:)
      allow(s).to receive(:call).and_raise(error)
      s
    end

    it 'propagates out of #run rather than scoring a verdict' do
      runner = described_class.new(base_url:, profile:)
      expect { runner.run([raising_scenario('CrossTenantRead')]) }
        .to raise_error(RuntimeError, /create_owned failed/)
    end

    it 'does not run the scenarios queued after it' do
      later = make_scenario('Later', blocked_verdict)
      runner = described_class.new(base_url:, profile:)
      expect { runner.run([raising_scenario('Boom'), later]) }.to raise_error(RuntimeError)
      expect(later).not_to have_received(:call)
    end
  end
end
