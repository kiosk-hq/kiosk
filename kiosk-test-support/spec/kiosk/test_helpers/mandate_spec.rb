# frozen_string_literal: true

require 'kiosk/test_helpers/mandate'

RSpec.describe Kiosk::TestHelpers::Mandate do
  let(:key) { OpenSSL::PKey.generate_key('ED25519') }
  let(:checkout_jwt) do
    JWT.encode({ merchant: { id: 'https://shop.example', name: 'Shop' }, currency: 'eur', total_amount_cents: 450 }, key, 'EdDSA')
  end

  describe '.sign' do
    let(:sd_jwt) { described_class.sign(key, { vct: 'mandate.payment.1' }) }

    it 'signs an SD-JWT whose one digest names the one disclosure, the mandate' do
      jwt, disclosure = sd_jwt.split('~')
      payload, header = JWT.decode(jwt, key, true, algorithm: 'EdDSA')

      expect(sd_jwt).to end_with('~')
      expect(header).to include('typ' => 'dc+sd-jwt')
      expect(payload).to eq('_sd_alg' => 'sha-256', 'delegate_payload' => [{ '...' => described_class.digest(disclosure) }])
      expect(described_class.content(sd_jwt)).to eq('vct' => 'mandate.payment.1')
    end

    it 'salts each disclosure, so one mandate signs to other bytes each time' do
      expect(sd_jwt).not_to eq(described_class.sign(key, { vct: 'mandate.payment.1' }))
    end
  end

  describe '.pay' do
    it 'binds the payment mandate to the checkout by hash, and copies its merchant and amount' do
      mandates = described_class.pay(key, checkout_jwt).transform_values { described_class.content(it) }

      expect(mandates[:checkout]).to include('vct' => 'mandate.checkout.1', 'checkout_jwt' => checkout_jwt)
      expect(mandates[:payment]).to include('transaction_id' => mandates[:checkout]['checkout_hash'],
                                            'payee' => { 'id' => 'https://shop.example', 'name' => 'Shop' },
                                            'payment_amount' => { 'amount' => 450, 'currency' => 'eur' })
      expect(mandates.values.map { it['exp'] - it['iat'] }).to eq([600, 600])
    end
  end
end
