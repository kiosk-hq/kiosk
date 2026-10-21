# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.shared_context 'with a stored customer Stripe no longer knows' do
  include_context 'with a Stripe adapter'

  let(:store) { { 'user-1' => 'cus_gone' } }
  let(:stale_adapter) { build_adapter(resolver: ->(uid) { store[uid] }, saver: ->(uid, cid) { store[uid] = cid }) }

  before do
    missing = Stripe::InvalidRequestError.new("No such customer: 'cus_gone'", 'id', code: 'resource_missing')
    allow(stripe.customers).to receive(:retrieve).with('cus_gone').and_raise(missing)
    allow(stripe.payment_methods).to receive(:list).with(customer: 'cus_gone', type: 'card', limit: 1).and_raise(missing)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe do
  describe 'with a stored customer Stripe no longer knows' do
    include_context 'with a stored customer Stripe no longer knows'

    it 'requires setup' do
      expect(stale_adapter.setup_required?(user_id: 'user-1')).to be true
    end

    it 'mints a fresh customer for the setup page and saves it in place of the stale one' do
      stub_no_outstanding_session
      allow(stripe.customers).to receive(:create).and_return(Stripe::Customer.construct_from(id: 'cus_fresh'))
      stub_fresh_session

      expect(stale_adapter.setup_url(user_id: 'user-1', return_url: return_url)).to eq(fresh_url)
      expect(store['user-1']).to eq('cus_fresh')
      expect(stripe.checkout.sessions).to have_received(:create).with(hash_including(customer: 'cus_fresh'))
    end

    it 'refuses a charge with SetupRequired' do
      expect { stale_adapter.capture(checkout_mandate) }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end
  end

  describe 'with a stored customer Stripe deleted or cannot reach' do
    include_context 'with a stored customer Stripe no longer knows'

    it 'mints a fresh customer for the setup page when Stripe deleted the stored one' do
      allow(stripe.customers).to receive(:retrieve).with('cus_gone')
                                                   .and_return(Stripe::Customer.construct_from(id: 'cus_gone', deleted: true))
      stub_no_outstanding_session
      allow(stripe.customers).to receive(:create).and_return(Stripe::Customer.construct_from(id: 'cus_fresh'))
      stub_fresh_session

      stale_adapter.setup_url(user_id: 'user-1', return_url: return_url)
      expect(store['user-1']).to eq('cus_fresh')
    end

    it 'still raises any other Stripe error' do
      allow(stripe.payment_methods).to receive(:list).with(customer: 'cus_gone', type: 'card', limit: 1)
                                                     .and_raise(Stripe::APIConnectionError.new('timed out'))
      expect { stale_adapter.setup_required?(user_id: 'user-1') }.to raise_error(Stripe::APIConnectionError)
    end
  end
end
