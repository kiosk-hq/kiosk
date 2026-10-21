# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.shared_context 'with a paying profile whose mandate is swapped' do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::TestHelpers::Assistant.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(pay_for: pay_for_callable)
  end
end

RSpec.describe Kiosk::Redteam::Scenarios::MandatePrincipalSwap do
  # `POST /kiosk/pay` is a RESERVED endpoint the cutover did not touch: same
  # path, same success body shape. Only the error shape moved (problem document).
  # minimal_profile's create_owned is a plain lambda, so the only protocol traffic
  # is register ×2 and the single pay.

  describe '#call — non-vacuity' do
    include_context 'with a paying profile whose mandate is swapped'

    context 'when the server accepts a checkout signed for another account (broken — BREACH)' do
      it 'returns blocked: false' do
        stub_registers('a', 'b')
        stub_pay(status: 200) # server accepts the swapped checkout

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(200)
      end
    end

    context 'when the server rejects the checkout signed for another account (correct — BLOCKED)' do
      it 'returns blocked: true' do
        stub_registers('a', 'b')
        stub_pay(status: 403, code: 'forbidden') # rejects on principal mismatch

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(403)
      end
    end
  end

  # ── K-728 ────────────────────────────────────────────────────────────────
  #
  # Checkout verification is authorization: the operator signed the checkout
  # for A, not for B. A 402 means the instrument was declined before the
  # mandates were verified at all — the swap unexamined — and a 401 means B's
  # own token was rejected. Both used to score BLOCKED.
  describe '#call — only a 403 forbidden/rls_denied proves the binding was checked (K-728)' do
    include_context 'with a paying profile whose mandate is swapped'

    def stub_refused_pay(status, code)
      stub_registers('a', 'b')
      stub_pay(status: status, code: code)
    end

    it 'blocks on 403 rls_denied' do
      stub_refused_pay(403, 'rls_denied')
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    it 'does not block on a 402 decline' do
      stub_refused_pay(402, 'payment_failed')
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('want status 403')
    end

    it 'does not block on a 401' do
      stub_refused_pay(401, 'unauthenticated')
      expect(scenario.call(client, profile).blocked).to be(false)
    end

    it 'does not block on a 403 carrying an unrelated code' do
      stub_refused_pay(403, 'kyc_required')
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('want error.code')
    end

    it 'does not block on a 500' do
      stub_refused_pay(500, 'forbidden')
      expect(scenario.call(client, profile).blocked).to be(false)
    end
  end

  describe '#call — skip conditions' do
    include_context 'with a paying profile whose mandate is swapped'

    it 'skips when pay_for is nil' do
      p = Kiosk::Redteam::Profile.new(create_owned: ->(_c, _pr) { { id: 'x' } })
      expect(scenario.call(client, p).detail).to include('SKIP')
    end

    it 'skips when create_owned is nil' do
      p = Kiosk::Redteam::Profile.new(pay_for: pay_for_callable)
      expect(scenario.call(client, p).detail).to include('SKIP')
    end
  end
end
