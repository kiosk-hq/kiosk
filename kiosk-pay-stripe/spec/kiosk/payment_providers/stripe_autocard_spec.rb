# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

# TEST-ONLY `test_autocard` behaviour: the adapter simulates a completed
# SetupIntent so automated suites need no card-setup step / server-side route.
RSpec.describe Kiosk::PaymentProviders::Stripe, '#setup_required? with test_autocard' do
  include StripeAdapterHelpers

  it 'returns false even with a resolver and no saved card (setup auto-completed at capture)' do
    adapter = build_adapter(resolver: ->(_uid) {}, test_autocard: true)
    expect(adapter.setup_required?(user_id: 'u')).to be(false)
  end

  it 'still requires setup when test_autocard is off and the principal has no card' do
    adapter = build_adapter(resolver: ->(_uid) {}, test_autocard: false)
    # resolver returns nil ⇒ saved_method? false ⇒ setup required
    expect(adapter.setup_required?(user_id: 'u')).to be(true)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#capture with test_autocard' do
  include StripeAdapterHelpers

  let(:cart) { double('CartMandate', user_id: 'u', total_amount_cents: 500, currency: 'eur', id: 'cart-1') }

  it 'auto-provisions a card then charges off_session when the principal has none' do
    adapter = build_adapter(resolver: ->(_uid) {}, test_autocard: true) # no customer yet

    # The auto-provision path: attach_test_card creates the customer + saved card.
    expect(adapter).to receive(:attach_test_card).with(user_id: 'u').and_return('cus_auto')
    allow(Stripe::Customer).to receive(:retrieve).with('cus_auto').and_return(customer_double(id: 'cus_auto', default_pm: 'pm_auto'))
    expect(Stripe::PaymentIntent).to receive(:create).with(
      hash_including(customer: 'cus_auto', payment_method: 'pm_auto', off_session: true),
      anything
    ).and_return(double('PI', id: 'pi_auto', status: 'succeeded', amount_received: 500, created: 0))

    expect(adapter.capture(cart)[:psp_reference]).to eq('pi_auto')
  end

  it 'charges the existing saved card without re-provisioning when the customer already has one' do
    adapter = build_adapter(resolver: ->(_uid) { 'cus_existing' }, test_autocard: true)

    # The customer already has a saved card, so attach_test_card must NOT be
    # called and the on-file card is charged.
    expect(adapter).not_to receive(:attach_test_card)
    stub_customer(default_pm: 'pm_onfile')
    expect(Stripe::PaymentIntent).to receive(:create).with(
      hash_including(customer: 'cus_existing', payment_method: 'pm_onfile', off_session: true),
      anything
    ).and_return(double('PI', id: 'pi_existing', status: 'succeeded', amount_received: 500, created: 0))

    expect(adapter.capture(cart)[:psp_reference]).to eq('pi_existing')
  end
end
