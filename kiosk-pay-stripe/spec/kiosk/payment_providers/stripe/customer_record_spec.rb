# frozen_string_literal: true

require "active_record"
require "kiosk/payment_providers/stripe/customer_record"

RSpec.describe Kiosk::PaymentProviders::Stripe::CustomerRecord do
  def migrate(direction)
    migration = Class.new(ActiveRecord::Migration[8.1]) do
      def change = Kiosk::PaymentProviders::Stripe::CustomerRecord.create_table(self)
    end
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
    described_class.reset_column_information
  end

  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    migrate(:up)
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  it "types user_id as the configured user id type" do
    expect(described_class.columns_hash["user_id"].sql_type).to eq("uuid")

    migrate(:down)
    allow(Kiosk.configuration).to receive(:user_id_type).and_return(:bigint)
    migrate(:up)
    expect(described_class.columns_hash["user_id"].sql_type).to eq("bigint")
  ensure
    migrate(:down)
    allow(Kiosk.configuration).to receive(:user_id_type).and_call_original
    migrate(:up)
  end

  it "resolves nothing for a principal it has never seen" do
    expect(described_class.resolve("user-unknown")).to be_nil
  end

  it "resolves the customer it saved, and a second save replaces it" do
    described_class.save("user-1", "cus_first")
    described_class.save("user-1", "cus_second")

    expect(described_class.resolve("user-1")).to eq("cus_second")
    expect(described_class.where(user_id: "user-1").count).to eq(1)
  end

  it "is what the adapter uses when no resolver and saver are given" do
    adapter = Kiosk::PaymentProviders::Stripe.new(api_key: "sk_test_dummy")
    described_class.save("user-2", "cus_two")
    allow(::Stripe::Customer).to receive(:retrieve).with("cus_two")
      .and_return(double("Customer", id: "cus_two", invoice_settings: double(default_payment_method: "pm_1")))

    expect(adapter.saved_method?(user_id: "user-2")).to be(true)
  end
end
