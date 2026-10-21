# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.shared_context 'with a profile that pays in euros' do
  subject(:scenario) { described_class.new }

  let(:client)  { Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL) }

  let(:profile) { minimal_profile(currency: 'eur', pay_for: pay_for_callable) }
end

RSpec.describe Kiosk::Redteam::Scenarios::WrongCurrencyPayment do
  describe '#call — non-vacuity' do
    include_context 'with a profile that pays in euros'

    context 'when the operator settles a payment in a currency other than its checkout (BREACH)' do
      it 'returns blocked: false' do
        stub_registers('a')
        stub_pay(status: 200)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include('usd payment of a EUR checkout settled')
      end
    end

    context 'when the operator refuses it' do
      it 'returns blocked: true' do
        stub_registers('a')
        stub_pay(status: 403, code: 'forbidden')

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end
    end

    # A 401 IS NOT A MANDATE CHECK. It says the credential was rejected, so the
    # payment never reached the check; delegating to the gem's generic
    # `blocked?` set would score that a BLOCK and print a refusal for an attack
    # that never executed, which is why this scenario names its status.
    it 'does not score a 401 as a refusal — the payment never reached the mandate check' do
      stub_registers('a')
      stub_pay(status: 401, code: 'unauthenticated')

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('want status 403')
    end

    # A crash is not a mandate check. The operator that 500s on a foreign
    # currency has not refused it — it has fallen over on the way to deciding.
    it 'does not score a 500 as a refusal' do
      stub_registers('a')
      stub_pay(status: 500, code: 'internal_error')

      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  describe 'the probed currency' do
    include_context 'with a profile that pays in euros'

    it "denominates the payment mandate in a currency that is NOT the checkout's, at the checkout's amount" do
      stub_registers('a')
      captured = nil
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .with do |req|
        captured = JSON.parse(req.body)
        true
      end
        .to_return(wire_return(status: 403, code: 'forbidden'))

      scenario.call(client, profile)

      expect(captured).not_to be_nil
      payment = Kiosk::TestHelpers::Mandate.content(captured.fetch('payment_mandate'))
      expect(payment['payment_amount']).to eq('amount' => 100, 'currency' => 'usd')
    end

    # An operator that prices in dollars must not be probed with dollars: the
    # payment would never have been foreign, and BLOCKED would be printed for an
    # attack that did not happen.
    it 'picks a different currency for a dollar-priced operator' do
      stub_registers('a')
      captured = nil
      stub_request(:post, "#{BASE_URL}/kiosk/pay")
        .with do |req|
        captured = JSON.parse(req.body)
        true
      end
        .to_return(wire_return(status: 403, code: 'forbidden'))

      usd = minimal_profile(currency: 'usd', pay_for: pay_for_callable)
      verdict = scenario.call(client, usd)

      payment = Kiosk::TestHelpers::Mandate.content(captured.fetch('payment_mandate'))
      expect(payment.dig('payment_amount', 'currency')).to eq('eur')
      expect(verdict.detail).to be_a(String)
    end
  end

  describe '#call — skips' do
    include_context 'with a profile that pays in euros'

    it 'skips when the profile names no currency' do
      verdict = scenario.call(client, minimal_profile(pay_for: pay_for_callable))

      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('no currency')
    end

    it 'skips when the profile names no checkout to pay' do
      verdict = scenario.call(client, minimal_profile(currency: 'eur'))

      expect(verdict.skipped).to be(true)
      expect(verdict.detail).to include('no pay_for')
    end

    it 'skips when the profile cannot create an owned resource' do
      no_owner = Kiosk::Redteam::Profile.new(currency: 'eur', pay_for: pay_for_callable)

      verdict = scenario.call(client, no_owner)

      expect(verdict.skipped).to be(true)
      expect(verdict.detail).to include('no create_owned')
    end
  end
end
