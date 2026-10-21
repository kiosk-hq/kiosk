# frozen_string_literal: true

require 'kiosk/test_helpers/stripe_mock'

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

  # Stubs the cards Stripe lists for the mapped Customer, newest first.
  def stub_cards(*ids)
    cards = ids.first(1).map { |id| Stripe::PaymentMethod.construct_from(id: id) }
    allow(stripe.payment_methods).to receive(:list).with(customer: 'cus_existing', type: 'card', limit: 1)
                                                   .and_return(Stripe::ListObject.construct_from(data: cards))
  end

  # A listed Checkout Session as the SDK would return it.
  def listed_session(mode: 'setup', success_url: SUCCESS_URL, url: 'https://checkout.stripe.com/setup/OUTSTANDING')
    Stripe::Checkout::Session.construct_from(mode: mode, success_url: success_url, url: url)
  end

  def stub_listed_sessions(*sessions)
    allow(stripe.checkout.sessions).to receive(:list).and_return(Stripe::ListObject.construct_from(data: sessions))
  end

  def stub_no_outstanding_session
    stub_listed_sessions
  end

  def stub_fresh_session
    allow(stripe.checkout.sessions).to receive(:create).and_return(Stripe::Checkout::Session.construct_from(url: FRESH_URL))
  end

  # The SDK services of every adapter an example builds; the examples stub them.
  def stripe = @stripe ||= Stripe::StripeClient.new('sk_test_dummy').v1

  # Yields an adapter on stripe-mock.
  def with_stripe_mock
    url = Kiosk::TestHelpers::StripeMock.start

    allow(Stripe::StripeClient).to receive(:new).and_call_original
    yield build_adapter(api_base: url)
  end
end

RSpec.shared_context 'with a Stripe adapter' do
  include StripeAdapterHelpers

  subject(:adapter) { build_adapter }

  let(:return_url)  { StripeAdapterHelpers::RETURN_URL }
  let(:success_url) { StripeAdapterHelpers::SUCCESS_URL }
  let(:fresh_url)   { StripeAdapterHelpers::FRESH_URL }

  let(:checkout_mandate) do
    Kiosk::Mandate::CheckoutMandate.new(
      reference: 'checkout-1', checkout_hash: 'hash-1', user_id: 'user-1',
      agent_id: 'agent-1', issuer: 'https://demo.example',
      line_items: [{ sku: 'pizza', qty: 1 }], total_amount_cents: 1599,
      currency: 'eur', expires_at: nil, sd_jwt: 'sd-jwt'
    )
  end

  # Each adapter calls `stripe`; the mapped customer exists at Stripe unless an example says otherwise.
  before do
    services = stripe
    allow(Stripe::StripeClient).to receive(:new).and_return(instance_double(Stripe::StripeClient, v1: services))
    allow(stripe.customers).to receive(:retrieve).with('cus_existing')
                                                 .and_return(Stripe::Customer.construct_from(id: 'cus_existing'))
  end
end
