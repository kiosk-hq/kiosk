# frozen_string_literal: true

require 'kiosk/payment_providers/stripe/customer_record'
require_relative '../../../support/stripe_customers_table'

RSpec.describe Kiosk::PayStripe::Generators::InstallGenerator do
  around do |example|
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    example.run
  ensure
    ActiveRecord::Base.remove_connection
  end

  it 'writes the DDL into the migration, so migrating needs no kiosk-pay-stripe code' do
    expect(StripeCustomersTable.generate).not_to include('Kiosk::')
  end

  it 'types user_id as uuid unless told otherwise' do
    StripeCustomersTable.migrate(:up)

    expect(Kiosk::PaymentProviders::Stripe::CustomerRecord.columns_hash['user_id'].sql_type).to eq('uuid')
  end

  it 'types user_id as --user-id-type says' do
    StripeCustomersTable.migrate(:up, '--user-id-type=bigint')

    expect(Kiosk::PaymentProviders::Stripe::CustomerRecord.columns_hash['user_id'].sql_type).to eq('bigint')
  end

  it 'keeps one row per principal' do
    StripeCustomersTable.migrate(:up)

    expect(ActiveRecord::Base.connection.indexes(:stripe_customers).map { [it.columns, it.unique] })
      .to eq([[%w[user_id], true]])
  end
end
