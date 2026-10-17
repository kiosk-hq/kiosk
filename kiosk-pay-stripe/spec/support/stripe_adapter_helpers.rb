# frozen_string_literal: true

require_relative 'stripe_mock'

# Adapters and SDK doubles that the Stripe adapter specs share.
module StripeAdapterHelpers
  RETURN_URL  = 'https://shop.example/kiosk/payment_setup/return'
  SUCCESS_URL = "#{RETURN_URL}?session_id={CHECKOUT_SESSION_ID}".freeze
  FRESH_URL   = 'https://checkout.stripe.com/setup/fresh'

  # By default the resolver maps 'user-1' to 'cus_existing' and nothing else.
  def build_adapter(resolver: ->(uid) { uid == 'user-1' ? 'cus_existing' : nil },
                    saver: ->(_uid, _cid) {}, **)
    described_class.new(api_key: 'sk_test_dummy', customer_resolver: resolver, customer_saver: saver, **)
  end

  # An adapter whose resolver knows no principal.
  def no_customer_adapter
    build_adapter(resolver: ->(_uid) {})
  end

  def customer_double(id: 'cus_existing', default_pm: nil)
    double('Customer', id: id, invoice_settings: double('InvoiceSettings', default_payment_method: default_pm))
  end

  # Stubs the mapped Customer. With `listed`, also stubs the cards Stripe lists for it.
  def stub_customer(default_pm: nil, listed: nil)
    allow(Stripe::Customer).to receive(:retrieve).with('cus_existing').and_return(customer_double(default_pm: default_pm))
    return if listed.nil?

    allow(Stripe::PaymentMethod).to receive(:list).with(customer: 'cus_existing', type: 'card')
                                                  .and_return(double('PMList', data: listed.map { |id| double('PM', id: id) }))
  end

  # A listed Checkout Session as the SDK would return it.
  def listed_session(mode: 'setup', success_url: SUCCESS_URL, url: 'https://checkout.stripe.com/setup/OUTSTANDING')
    double('ListedSession', mode: mode, success_url: success_url, url: url)
  end

  def expect_default_set(customer_id, payment_method)
    expect(Stripe::Customer).to receive(:update).with(
      customer_id,
      { invoice_settings: { default_payment_method: payment_method } }
    ).and_return(double('Customer'))
  end

  def stub_listed_sessions(*sessions)
    allow(Stripe::Checkout::Session).to receive(:list).and_return(double('SessionList', data: sessions))
  end

  def stub_no_outstanding_session
    stub_listed_sessions
  end

  def stub_fresh_session
    allow(Stripe::Checkout::Session).to receive(:create).and_return(double('CheckoutSession', url: FRESH_URL))
  end

  def expect_fresh_session
    expect(Stripe::Checkout::Session).to receive(:create).and_return(double('CheckoutSession', url: FRESH_URL))
  end

  # Points the SDK at stripe-mock for the block. Skips when stripe-mock is not installed.
  def with_stripe_mock
    url = StripeMock.start
    skip 'stripe-mock not installed (brew install stripe-mock)' unless url

    saved_base = Stripe.api_base
    Stripe.api_base = url
    yield
  ensure
    Stripe.api_base = saved_base if saved_base
  end
end

RSpec.shared_context 'with a Stripe adapter' do
  include StripeAdapterHelpers

  subject(:adapter) { build_adapter }

  let(:return_url)  { StripeAdapterHelpers::RETURN_URL }
  let(:success_url) { StripeAdapterHelpers::SUCCESS_URL }
  let(:fresh_url)   { StripeAdapterHelpers::FRESH_URL }

  let(:cart_mandate) do
    Kiosk::Mandate::CartMandate.new(
      id: 'cart-1', intent_mandate_id: 'intent-1', user_id: 'user-1',
      agent_id: 'agent-1', issuer: 'https://demo.example',
      line_items: [{ sku: 'pizza', qty: 1 }], total_amount_cents: 1599,
      currency: 'eur', expires_at: nil, created_at: nil, raw_jws: 'jws'
    )
  end

  # The mapped customer exists at Stripe unless an example says otherwise.
  before do
    allow(Stripe::Customer).to receive(:retrieve).with('cus_existing')
                                                 .and_return(double('Customer', id: 'cus_existing'))
  end
end
