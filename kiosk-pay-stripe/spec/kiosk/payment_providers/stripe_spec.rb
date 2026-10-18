# frozen_string_literal: true

require_relative '../../support/stripe_adapter_helpers'

RSpec.describe Kiosk::PaymentProviders::Stripe do
  include_context 'with a Stripe adapter'

  it 'is a Kiosk payment provider' do
    expect(adapter).to be_a(Kiosk::PaymentProviders::Base)
  end

  it 'exposes a VERSION' do
    expect(Kiosk::PaymentProviders::Stripe::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#setup_url' do
  include_context 'with a Stripe adapter'

  before { stub_no_outstanding_session }

  it 'creates a Checkout Session in setup mode for an existing customer and returns the url' do
    # success_url is the engine's return page plus Stripe's session-id
    # placeholder; client_reference_id is how that page learns whose human it is.
    expect(stripe.checkout.sessions).to receive(:create).with(
      mode: 'setup',
      customer: 'cus_existing',
      client_reference_id: 'user-1',
      payment_method_types: ['card'],
      success_url: success_url
    ).and_return(double('CheckoutSession', url: 'https://checkout.stripe.com/setup/abc'))

    url = adapter.setup_url(user_id: 'user-1', return_url: return_url)
    expect(url).to eq('https://checkout.stripe.com/setup/abc')
  end

  # Without explicit payment_method_types a setup-mode session needs a
  # `currency`, and its hosted page errors when both are missing.
  it 'always pins explicit payment_method_types so setup mode needs no currency (K-473)' do
    session = double('CheckoutSession', url: 'https://checkout.stripe.com/setup/abc')

    expect(stripe.checkout.sessions).to receive(:create) do |params|
      expect(params[:mode]).to eq('setup')
      expect(params[:payment_method_types]).to eq(['card']),
                                               'setup-mode session must pin payment_method_types or Stripe requires `currency`'
      expect(params).to have_key(:success_url)
      session
    end

    adapter.setup_url(user_id: 'user-1', return_url: return_url)
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#setup_url for a new principal' do
  include_context 'with a Stripe adapter'

  before { stub_no_outstanding_session }

  it 'creates a new Customer when none exists, persists the mapping, and returns the session url' do
    saved         = {}
    fresh_adapter = build_adapter(resolver: ->(_uid) {}, saver: ->(uid, cid) { saved[uid] = cid })

    expect(stripe.customers).to receive(:create).with({ name: 'principal-user-2' })
                                                .and_return(double('Customer', id: 'cus_new'))
    expect(stripe.checkout.sessions).to receive(:create).with(
      hash_including(customer: 'cus_new', mode: 'setup', success_url: success_url)
    ).and_return(double('CheckoutSession', url: 'https://checkout.stripe.com/setup/xyz'))

    url = fresh_adapter.setup_url(user_id: 'user-2', return_url: return_url)
    expect(url).to eq('https://checkout.stripe.com/setup/xyz')
    expect(saved['user-2']).to eq('cus_new')
  end
end

RSpec.describe Kiosk::PaymentProviders::Stripe, '#setup_return_user_id' do
  include_context 'with a Stripe adapter'

  it 'answers the principal Stripe says the returned session was minted for' do
    allow(stripe.checkout.sessions).to receive(:retrieve).with('cs_1')
                                                         .and_return(double('CheckoutSession', client_reference_id: 'user-1'))
    expect(adapter.setup_return_user_id({ 'session_id' => 'cs_1' })).to eq('user-1')
  end

  it 'answers nil without asking Stripe when the request names no session' do
    expect(stripe.checkout.sessions).not_to receive(:retrieve)
    expect(adapter.setup_return_user_id({})).to be_nil
  end
end
