# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Stripe do
  subject(:adapter) { described_class.new(api_key: "sk_test_dummy") }

  it "is a Kiosk payment provider" do
    expect(adapter).to be_a(Kiosk::PaymentProviders::Base)
  end

  it "exposes a VERSION" do
    expect(Kiosk::PaymentProviders::Stripe::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
