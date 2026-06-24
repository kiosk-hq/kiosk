# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Stripe do
  subject(:adapter) { described_class.new(api_key: "sk_test_dummy") }

  it "is a Kiosk payment provider" do
    expect(adapter).to be_a(Kiosk::PaymentProviders::Base)
  end

  it "exposes a VERSION" do
    expect(Kiosk::PaymentProviders::Stripe::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  let(:cart_mandate) do
    Kiosk::Mandate::CartMandate.new(
      id: "cart-1", intent_mandate_id: "intent-1", user_id: "user-1",
      agent_id: "agent-1", issuer: "https://demo.example",
      line_items: [{ sku: "pizza", qty: 1 }], total_amount_cents: 1599,
      currency: "eur", expires_at: nil, created_at: nil, raw_jws: "jws",
    )
  end

  describe "#capture" do
    it "creates a confirmed automatic-capture PaymentIntent from the mandate" do
      pi = double("PaymentIntent", id: "pi_123", amount_received: 1599, created: 1_700_000_000)

      expect(::Stripe::PaymentIntent).to receive(:create).with(
        {
          amount: 1599, currency: "eur",
          payment_method: "pm_card_visa", confirm: true,
          capture_method: "automatic",
          metadata: { cart_mandate_id: "cart-1" },
        },
        { idempotency_key: "cart-1-capture" },
      ).and_return(pi)

      result = adapter.capture(cart_mandate)

      expect(result[:psp_reference]).to eq("pi_123")
      expect(result[:settled_amount_cents]).to eq(1599)
      expect(result[:settled_at]).to eq(Time.at(1_700_000_000).utc)
    end
  end

  describe "#authorize" do
    it "creates a manual-capture hold and returns its reference" do
      pi = double("PaymentIntent", id: "pi_hold", client_secret: "cs_1", status: "requires_capture")

      expect(::Stripe::PaymentIntent).to receive(:create).with(
        {
          amount: 1599, currency: "eur",
          payment_method: "pm_card_visa", confirm: true,
          capture_method: "manual",
          metadata: { cart_mandate_id: "cart-1" },
        },
        { idempotency_key: "cart-1-auth" },
      ).and_return(pi)

      result = adapter.authorize(cart_mandate)

      expect(result[:stripe_payment_intent_id]).to eq("pi_hold")
      expect(result[:client_secret]).to eq("cs_1")
      expect(result[:status]).to eq("requires_capture")
    end
  end
end
