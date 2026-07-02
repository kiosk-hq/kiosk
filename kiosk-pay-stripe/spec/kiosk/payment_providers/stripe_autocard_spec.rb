# frozen_string_literal: true

require "kiosk/payment_providers/stripe"

# TEST-ONLY `test_autocard` behaviour: the adapter simulates a completed
# SetupIntent so automated suites need no card-setup step / server-side route.
RSpec.describe Kiosk::PaymentProviders::Stripe do
  describe "#setup_required? with test_autocard" do
    it "returns false even with a resolver and no saved card (setup auto-completed at capture)" do
      adapter = described_class.new(
        api_key:           "sk_test_x",
        customer_resolver: ->(_uid) { nil },
        test_autocard:     true,
      )
      expect(adapter.setup_required?(user_id: "u")).to be(false)
    end

    it "still requires setup when test_autocard is off and the principal has no card" do
      adapter = described_class.new(
        api_key:           "sk_test_x",
        customer_resolver: ->(_uid) { nil },
        test_autocard:     false,
      )
      # resolver returns nil ⇒ saved_method? false ⇒ setup required
      expect(adapter.setup_required?(user_id: "u")).to be(true)
    end
  end

  describe "#capture with test_autocard" do
    it "auto-provisions a card then charges off_session when the principal has none" do
      adapter = described_class.new(
        api_key:           "sk_test_x",
        customer_resolver: ->(_uid) { nil }, # no customer yet
        test_autocard:     true,
      )
      cart = double("CartMandate", user_id: "u", total_amount_cents: 500, currency: "eur", id: "cart-1")

      # The auto-provision path: attach_test_card creates the customer + saved card.
      expect(adapter).to receive(:attach_test_card).with(user_id: "u").and_return("cus_auto")
      allow(adapter).to receive(:saved_payment_method_for).with("cus_auto").and_return("pm_auto")

      expect(::Stripe::PaymentIntent).to receive(:create).with(
        hash_including(customer: "cus_auto", payment_method: "pm_auto", off_session: true),
        anything,
      ).and_return(double("PI", id: "pi_auto", amount_received: 500, created: 0))

      result = adapter.capture(cart)
      expect(result[:psp_reference]).to eq("pi_auto")
    end
  end
end
