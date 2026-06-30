# frozen_string_literal: true

# Real Stripe test-mode round-trip. Skipped unless STRIPE_SECRET_KEY is set
# (an sk_test_… key). Never moves real money.
#
# NOTE: real `pi_…` verification needs the operator's test key. Without it,
# these examples are skipped. The mocked suite (stripe_spec.rb) runs without
# a key and covers all new methods with WebMock/RSpec doubles.
RSpec.describe Kiosk::PaymentProviders::Stripe, :integration do
  before do
    skip "set STRIPE_SECRET_KEY (sk_test_…) to run" unless ENV["STRIPE_SECRET_KEY"]
  end

  # In-memory principal→customer store (replaces the app's stripe_customers table).
  let(:customer_store) { {} }

  subject(:adapter) do
    described_class.new(
      api_key:           ENV["STRIPE_SECRET_KEY"],
      customer_resolver: ->(uid) { customer_store[uid] },
      customer_saver:    ->(uid, cid) { customer_store[uid] = cid },
    )
  end

  let(:user_id) { "integration-test-user-#{Process.pid}" }

  let(:cart_mandate) do
    Kiosk::Mandate::CartMandate.new(
      id: "cart-int-#{Process.pid}", intent_mandate_id: "i", user_id: user_id,
      agent_id: "a", issuer: "https://demo.example",
      line_items: [{ sku: "pizza", qty: 1 }], total_amount_cents: 1599,
      currency: "eur", expires_at: nil, created_at: nil, raw_jws: "jws",
    )
  end

  describe "#attach_test_card + #capture + #refund (full off_session round-trip)" do
    it "attaches a test card then captures and refunds a real test payment" do
      # Simulate a completed SetupIntent programmatically (no human at hosted page).
      cus_id = adapter.attach_test_card(user_id: user_id)
      expect(cus_id).to start_with("cus_")
      expect(customer_store[user_id]).to eq(cus_id)

      # saved_method? should now return true.
      expect(adapter.saved_method?(user_id: user_id)).to be true

      # off_session capture against the saved card → real pi_…
      captured = adapter.capture(cart_mandate, payment_method: nil)
      expect(captured[:settled_amount_cents]).to eq(1599)
      expect(captured[:psp_reference]).to start_with("pi_")

      settlement = Kiosk::Mandate::Settlement.new(
        id: "s", cart_mandate_id: cart_mandate.id, user_id: user_id, agent_id: "a",
        issuer: "https://demo.example", psp_reference: captured[:psp_reference],
        settled_amount_cents: 1599, currency: "eur", settled_at: nil, raw_jws: "jws",
      )

      refunded = adapter.refund(settlement)
      expect(refunded[:refund_id]).to start_with("re_")
    end
  end

  describe "#setup_url" do
    it "returns a hosted Stripe Checkout URL for the setup flow" do
      url = adapter.setup_url(user_id: user_id, return_url: "https://example.com/return")
      expect(url).to start_with("https://checkout.stripe.com/")
    end
  end

  describe "#saved_method? before card setup" do
    it "returns false for a new user with no card on file" do
      fresh_user = "no-card-user-#{Process.pid}"
      expect(adapter.saved_method?(user_id: fresh_user)).to be false
    end
  end
end
