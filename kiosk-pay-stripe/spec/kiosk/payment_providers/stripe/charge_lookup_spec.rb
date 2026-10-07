# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Stripe::ChargeLookup do
  subject(:lookup) { described_class.new }

  let(:cart) { { cart_mandate_id: "cart-1", amount_cents: 1599, currency: "eur" } }

  def intent(status:, cart_mandate_id: "cart-1", amount: 1599, currency: "eur")
    double("PaymentIntent", status: status, amount: amount, currency: currency,
                            metadata: { "cart_mandate_id" => cart_mandate_id })
  end

  def stripe_answers(*intents)
    allow(::Stripe::PaymentIntent).to receive(:search)
      .with(query: "metadata['cart_mandate_id']:'cart-1'")
      .and_return(double("SearchResult", data: intents))
  end

  it "is :paid when an intent for this cart succeeded" do
    stripe_answers(intent(status: "requires_payment_method"), intent(status: "succeeded"))
    expect(lookup.outcome(**cart)).to eq(:paid)
  end

  it "is :not_charged when every intent for this cart was cancelled or declined" do
    stripe_answers(intent(status: "canceled"), intent(status: "requires_payment_method"))
    expect(lookup.outcome(**cart)).to eq(:not_charged)
  end

  it "is :unknown while an intent for this cart is still processing" do
    stripe_answers(intent(status: "canceled"), intent(status: "processing"))
    expect(lookup.outcome(**cart)).to eq(:unknown)
  end

  it "is :unknown when no intent names this cart" do
    stripe_answers
    expect(lookup.outcome(**cart)).to eq(:unknown)
  end

  it "ignores an intent for another amount, currency or cart" do
    stripe_answers(intent(status: "canceled", amount: 999),
                   intent(status: "canceled", currency: "usd"),
                   intent(status: "canceled", cart_mandate_id: "cart-2"))
    expect(lookup.outcome(**cart)).to eq(:unknown)
  end

  it "is :unknown when Stripe fails" do
    allow(::Stripe::PaymentIntent).to receive(:search).and_raise(::Stripe::APIConnectionError, "down")
    expect(lookup.outcome(**cart)).to eq(:unknown)
  end

  it "refuses an id that could end the search query's quote" do
    expect(::Stripe::PaymentIntent).not_to receive(:search)
    expect(lookup.outcome(**cart, cart_mandate_id: "x' OR status:'succeeded")).to eq(:unknown)
  end
end
