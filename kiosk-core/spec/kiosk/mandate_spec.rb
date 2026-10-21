# frozen_string_literal: true

RSpec.describe Kiosk::Mandate do
  let(:now) { Time.now }

  describe Kiosk::Mandate::CheckoutMandate do
    let(:args) do
      { reference: 'r-1', checkout_hash: 'h-1', user_id: 'u-1', agent_id: 'a-1',
        issuer: 'https://acme.example', line_items: [{ order_id: 'o-1' }, { qty: 1, price_cents: 350 }],
        total_amount_cents: 350, currency: 'usd', expires_at: now + 600, sd_jwt: 'eyJ...~WyJ...~' }
    end

    it 'constructs with all fields' do
      m = described_class.new(**args)
      expect([m.checkout_hash, m.line_items.size, m.total_amount_cents]).to eq(['h-1', 2, 350])
    end

    it 'is a value type (equal by fields)' do
      first, second = Array.new(2) { described_class.new(**args) }
      expect(first).to eq(second)
    end
  end

  describe Kiosk::Mandate::PaymentMandate do
    let(:args) do
      { reference: 'r-2', transaction_id: 'h-1', user_id: 'u-1', agent_id: 'a-1',
        issuer: 'https://acme.example', payment_instrument: 'on_file', amount_cents: 350,
        currency: 'usd', expires_at: now + 600, sd_jwt: 'eyJ...~WyJ...~' }
    end

    it 'constructs with all fields' do
      m = described_class.new(**args)
      expect([m.transaction_id, m.payment_instrument, m.amount_cents]).to eq(['h-1', 'on_file', 350])
    end

    it 'is a value type (equal by fields)' do
      first, second = Array.new(2) { described_class.new(**args) }
      expect(first).to eq(second)
    end
  end
end
