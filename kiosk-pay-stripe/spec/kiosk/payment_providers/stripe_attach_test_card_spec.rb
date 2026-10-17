# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe, '#attach_test_card' do
  include_context 'with a Stripe adapter'

  it 'saves the card via a SetupIntent and sets the attached pm as the default, returning the customer_id' do
    expect(Stripe::SetupIntent).to receive(:create).with(
      hash_including(customer: 'cus_existing', payment_method: 'pm_card_visa', confirm: true, usage: 'off_session')
    ).and_return(double('SetupIntent', payment_method: 'pm_attached_1'))
    # The default is the SetupIntent's ATTACHED pm id, not the shared token.
    expect_default_set('cus_existing', 'pm_attached_1')

    expect(adapter.attach_test_card(user_id: 'user-1')).to eq('cus_existing')
  end

  it 'creates a new customer when none exists and saves the mapping before the SetupIntent' do
    saved         = {}
    fresh_adapter = build_adapter(resolver: ->(_uid) {}, saver: ->(uid, cid) { saved[uid] = cid })

    expect(Stripe::Customer).to receive(:create).with({ name: 'principal-user-new' })
                                                .and_return(double('Customer', id: 'cus_created'))
    expect(Stripe::SetupIntent).to receive(:create).with(
      hash_including(customer: 'cus_created', payment_method: 'pm_card_visa')
    ).and_return(double('SetupIntent', payment_method: 'pm_attached_2'))
    expect_default_set('cus_created', 'pm_attached_2')

    expect(fresh_adapter.attach_test_card(user_id: 'user-new')).to eq('cus_created')
    expect(saved['user-new']).to eq('cus_created')
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#attach_test_card with a custom payment method' do
  include_context 'with a Stripe adapter'

  it 'accepts a custom payment_method argument' do
    allow(Stripe::SetupIntent).to receive(:create).with(
      hash_including(customer: 'cus_existing', payment_method: 'pm_card_mastercard')
    ).and_return(double('SetupIntent', payment_method: 'pm_attached_mc'))
    allow(Stripe::Customer).to receive(:update).and_return(double('Customer'))

    expect(adapter.attach_test_card(user_id: 'user-1', payment_method: 'pm_card_mastercard')).to eq('cus_existing')
  end
end
