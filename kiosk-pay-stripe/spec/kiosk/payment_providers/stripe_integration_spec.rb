# frozen_string_literal: true

# Real Stripe test-mode round-trip. Skipped unless STRIPE_SECRET_KEY is set
# (an sk_test_… key). Never moves real money.
RSpec.describe Kiosk::PaymentProviders::Stripe, :integration do
  before do
    skip "set STRIPE_SECRET_KEY (sk_test_…) to run" unless ENV["STRIPE_SECRET_KEY"]
  end

  subject(:adapter) { described_class.new(api_key: ENV["STRIPE_SECRET_KEY"]) }

  let(:cart_mandate) do
    Kiosk::Mandate::CartMandate.new(
      id: "cart-int-#{Process.pid}", intent_mandate_id: "i", user_id: "u",
      agent_id: "a", issuer: "https://demo.example",
      line_items: [{ sku: "pizza", qty: 1 }], total_amount_cents: 1599,
      currency: "eur", expires_at: nil, created_at: nil, raw_jws: "jws",
    )
  end

  it "captures then refunds a real test payment" do
    captured = adapter.capture(cart_mandate)
    expect(captured[:settled_amount_cents]).to eq(1599)

    payment_mandate = Kiosk::Mandate::PaymentMandate.new(
      id: "p", cart_mandate_id: cart_mandate.id, user_id: "u", agent_id: "a",
      issuer: "https://demo.example", psp_reference: captured[:psp_reference],
      settled_amount_cents: 1599, currency: "eur", settled_at: nil, raw_jws: "jws",
    )

    refunded = adapter.refund(payment_mandate)
    expect(refunded[:refund_id]).to start_with("re_")
  end
end
