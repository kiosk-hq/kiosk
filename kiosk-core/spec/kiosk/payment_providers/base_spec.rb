# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Base do
  subject(:adapter) { described_class.new }

  describe '#setup_required?' do
    it 'returns false (default — an adapter with no card setup is never gated)' do
      expect(adapter.setup_required?(user_id: 'user-1')).to be(false)
    end
  end

  describe '#setup_url' do
    it 'raises NotImplementedError — an adapter whose setup_required? can answer true must implement it' do
      expect do
        adapter.setup_url(user_id: 'user-1', return_url: 'https://shop.example/kiosk/payment_setup/return')
      end.to raise_error(NotImplementedError, /setup_url must be implemented/)
    end
  end

  describe '#capture' do
    it 'raises NotImplementedError — subclasses must implement the charge' do
      expect do
        adapter.capture(:checkout_mandate, payment_method: 'pm_card_visa')
      end.to raise_error(NotImplementedError, /capture must be implemented/)
    end
  end

  describe '#refund' do
    it 'raises NotImplementedError — an adapter whose operator refunds must implement it' do
      expect { adapter.refund(psp_reference: 'pi_1', amount_cents: 100, key: 'order-1') }
        .to raise_error(NotImplementedError, /refund must be implemented/)
    end
  end

  describe '#resume' do
    it 'runs the capture again, which the adapter keys by the checkout mandate reference' do
      adapter = Class.new(described_class) { def capture(checkout, payment_method:) = [checkout, payment_method] }.new
      expect(adapter.resume(:checkout_mandate, payment_method: 'on_file')).to eq([:checkout_mandate, 'on_file'])
    end
  end
end
