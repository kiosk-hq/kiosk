# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# The gated action is `POST /kiosk/start_rental` — the verb name is the path
# segment, and `{reservation_id: …}` is the WHOLE body.
# (minimal_profile's create_owned is a plain lambda, so it makes no API call.)
RENTAL_OK = { 'scooter_code' => 'SK-001', 'rental_token' => 'rt-1', 'exp' => 4_102_444_800 }.freeze

RSpec.describe Kiosk::Redteam::Scenarios::UnpaidGatedAction do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      gated_action: 'start_rental',
      gated_args: ->(ref) { { reservation_id: ref[:id] } }
    )
  end

  describe '#call — non-vacuity' do
    context 'when the server allows the gated action without payment (broken — BREACH)' do
      it 'returns blocked: false' do
        stub_registers('a')
        stub_action('start_rental', status: 200, body: RENTAL_OK)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context 'when the server blocks the gated action (correct — BLOCKED)' do
      it 'returns blocked: true' do
        stub_registers('a')
        stub_action('start_rental', status: 403, code: 'forbidden')

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end

    it 'sends the gated args as the body of POST /kiosk/start_rental, with no `name` field' do
      stub_registers('a')
      captured = nil
      stub_request(:post, verb_url('start_rental'))
        .with do |req|
        captured = req
        true
      end
        .to_return(problem_return('forbidden'))

      scenario.call(client, profile)

      expect(captured.uri.path).to eq('/kiosk/start_rental')
      expect(captured.headers['Authorization']).to eq("DPoP #{token_for('a')}")
      expect(JSON.parse(captured.body)).to eq('reservation_id' => 'res-1')
    end
  end

  # ── HTTP 402 on the gated action ─────────────────────────────────────────
  #
  # #run pays a `pow_required` that carries challenges, and the attack runs.
  # These stubs carry none: the shape of the two payment 402s, and of a toll a
  # provider demands again. The attack never executed, so the verdict is
  # could-not-test, or a breach for payment_failed, and never a pass.
  describe '#call — a 402 on the gated action is not a pass (K-736)' do
    def stub_toll(code)
      stub_registers('a')
      stub_action('start_rental', status: 402, code: code)
    end

    %w[pow_required payment_setup_required payment_failed].each do |code|
      it "does not block on 402 #{code}, and names it" do
        stub_toll(code)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.status).to eq(402)
        # payment_failed comes after every gate said yes; the other two come before the attack is read.
        expect(verdict.untested).to be(code != 'payment_failed')
        expect(verdict.detail).to include(code == 'payment_failed' ? 'No gate refused the attack.' : 'COULD NOT TEST')
        expect(verdict.detail).to include(code.inspect)
      end
    end

    it 'keeps the battery from going green on it' do
      stub_toll('pow_required')
      battery = Kiosk::Redteam::Battery.new(io: StringIO.new)
      battery.absorb(Kiosk::Redteam::Runner.new(base_url: BASE_URL, profile: profile).run([scenario]))

      expect(battery.report!).to eq(1)
      expect(battery.untested.size).to eq(1)
    end
  end

  # Coverage for submit_valid_kyc + the `if profile.requires_kyc` guard.
  # The other examples build their profile with requires_kyc defaulting to
  # false. This exercises the requires_kyc:true + kyc_valid path, so the helper
  # POSTs a valid attestation.
  describe '#call — requires_kyc:true drives submit_valid_kyc' do
    let(:kyc_profile) do
      minimal_profile(
        gated_action: 'start_rental',
        gated_args: ->(ref) { { reservation_id: ref[:id] } },
        requires_kyc: true,
        kyc_valid: ->(user_id) { "valid-kyc-jws-for-#{user_id}" }
      )
    end

    it 'submits the kyc_valid attestation for the registered principal' do
      stub_registers('a')
      stub_action('start_rental', status: 200, body: RENTAL_OK)
      kyc_stub = stub_request(:post, "#{BASE_URL}/kiosk/agents/kyc")
                 .with { |req| JSON.parse(req.body)['kyc_jws'] == 'valid-kyc-jws-for-user-a' }
                 .to_return(json_return(200, 'kyc_verified' => true, 'attributes' => {}))

      scenario.call(client, kyc_profile)

      # submit_valid_kyc ran: it called profile.kyc_valid with principal.user_id
      # and POSTed the resulting JWS to /kiosk/agents/kyc.
      expect(kyc_stub).to have_been_requested.once
    end
  end

  # ── The staged KYC ───────────────────────────────────────────────────────
  #
  # The staged KYC is the ONLY thing separating this scenario from MissingKyc.
  # If the provider refuses the attestation, a denial of the gated action could
  # be for want of KYC, so it cannot be scored as the payment gate.
  describe '#call — the staged KYC must be accepted (K-731)' do
    let(:kyc_profile) do
      minimal_profile(
        gated_action: 'start_rental',
        gated_args: ->(ref) { { reservation_id: ref[:id] } },
        requires_kyc: true,
        kyc_valid: ->(user_id) { "valid-kyc-jws-for-#{user_id}" }
      )
    end

    [403, 401, 500].each do |status|
      it "reports SETUP FAILED when the valid attestation is refused #{status}" do
        stub_registers('a')
        stub_action('start_rental', status: 200, body: RENTAL_OK)
        stub_kyc(status: status)

        verdict = scenario.call(client, kyc_profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(status)
        expect(verdict.detail).to include('SETUP FAILED')
        expect(verdict.detail).to include('KYC gate')
      end
    end

    it 'does not run the gated action once the KYC setup has failed' do
      stub_registers('a')
      run_stub = stub_action('start_rental', status: 200, body: RENTAL_OK)
      stub_kyc(status: 403)

      scenario.call(client, kyc_profile)

      expect(run_stub).not_to have_been_requested
    end

    it 'proceeds normally when the attestation is accepted' do
      stub_registers('a')
      stub_kyc(status: 200)
      stub_action('start_rental', status: 403, code: 'forbidden')

      expect(scenario.call(client, kyc_profile).blocked).to be(true)
    end

    # A profile with no KYC surface has no setup step to assert.
    it 'is unaffected when requires_kyc is false (no setup call to check)' do
      stub_registers('a')
      stub_action('start_rental', status: 403, code: 'forbidden')

      expect(scenario.call(client, profile).blocked).to be(true)
    end
  end

  describe '#call — skip conditions' do
    it 'skips when gated_action is nil' do
      p = minimal_profile
      expect(scenario.call(client, p).detail).to include('SKIP')
    end

    it 'skips when create_owned is nil' do
      p = Kiosk::Redteam::Profile.new(gated_action: 'start_rental')
      expect(scenario.call(client, p).detail).to include('SKIP')
    end
  end
end
