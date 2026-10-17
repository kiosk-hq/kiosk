# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe, '#setup_required?' do
  include_context 'with a Stripe adapter'

  it 'returns true when the resolver returns nil (principal has no Customer yet)' do
    expect(no_customer_adapter.setup_required?(user_id: 'user-unknown')).to be true
  end

  it 'returns true when the Customer exists but has no saved cards' do
    stub_customer(listed: [])

    expect(adapter.setup_required?(user_id: 'user-1')).to be true
  end

  it 'returns false when the Customer has a saved default payment method' do
    stub_customer(default_pm: 'pm_saved_123')

    expect(adapter.setup_required?(user_id: 'user-1')).to be false
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#saved_method?' do
  include_context 'with a Stripe adapter'

  it 'returns false when the resolver returns nil (unknown user)' do
    expect(no_customer_adapter.saved_method?(user_id: 'user-unknown')).to be false
  end

  it 'returns true when the customer has a default_payment_method on invoice_settings' do
    stub_customer(default_pm: 'pm_saved_123')

    expect(adapter.saved_method?(user_id: 'user-1')).to be true
  end

  it 'returns true when the customer has no default PM but has an attached card in the list' do
    stub_customer(listed: ['pm_attached_visa'])

    expect(adapter.saved_method?(user_id: 'user-1')).to be true
  end

  it 'returns false when the customer exists but has no saved cards' do
    stub_customer(listed: [])

    expect(adapter.saved_method?(user_id: 'user-1')).to be false
  end
end
