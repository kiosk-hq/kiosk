# frozen_string_literal: true

require 'kiosk/payment_providers/stripe/customer_record'
require_relative '../../../support/stripe_customers_table'

RSpec.describe Kiosk::PaymentProviders::Stripe::CustomerRecord do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    StripeCustomersTable.migrate(:up)
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  it 'resolves nothing for a principal it has never seen' do
    expect(described_class.resolve('user-unknown')).to be_nil
  end

  it 'resolves the customer it saved, and a second save replaces it' do
    described_class.save('user-1', 'cus_first')
    described_class.save('user-1', 'cus_second')

    expect(described_class.resolve('user-1')).to eq('cus_second')
    expect(described_class.where(user_id: 'user-1').count).to eq(1)
  end

  it 'is what the adapter uses when no resolver and saver are given' do
    services = Stripe::StripeClient.new('sk_test_dummy').v1
    allow(Stripe::StripeClient).to receive(:new).and_return(instance_double(Stripe::StripeClient, v1: services))
    allow(services.payment_methods).to receive(:list).with(customer: 'cus_two', type: 'card', limit: 1)
                                                     .and_return(double('PMList', data: [double('PM', id: 'pm_1')]))
    adapter = Kiosk::PaymentProviders::Stripe.new(api_key: 'sk_test_dummy')
    described_class.save('user-2', 'cus_two')

    expect(adapter.saved_method?(user_id: 'user-2')).to be(true)
  end
end
