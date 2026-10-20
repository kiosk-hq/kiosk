# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe do
  describe '#setup_required?' do
    include_context 'with a Stripe adapter'

    it 'returns true when the resolver returns nil (principal has no Customer yet)' do
      expect(no_customer_adapter.setup_required?(user_id: 'user-unknown')).to be true
    end

    it 'returns true when the Customer exists but has no saved cards' do
      stub_cards

      expect(adapter.setup_required?(user_id: 'user-1')).to be true
    end

    it 'returns false when the Customer has a saved card' do
      stub_cards('pm_saved_123')

      expect(adapter.setup_required?(user_id: 'user-1')).to be false
    end
  end

  describe '#saved_method?' do
    include_context 'with a Stripe adapter'

    it 'returns false when the resolver returns nil (unknown user)' do
      expect(no_customer_adapter.saved_method?(user_id: 'user-unknown')).to be false
    end

    it 'returns true when the customer has an attached card in the list' do
      stub_cards('pm_attached_visa')

      expect(adapter.saved_method?(user_id: 'user-1')).to be true
    end

    it 'returns false when the customer exists but has no saved cards' do
      stub_cards

      expect(adapter.saved_method?(user_id: 'user-1')).to be false
    end
  end
end
