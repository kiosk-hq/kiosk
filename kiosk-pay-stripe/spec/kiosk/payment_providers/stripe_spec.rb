# frozen_string_literal: true

RSpec.describe Kiosk::PaymentProviders::Stripe do
  subject(:adapter) { described_class.new(api_key: "sk_test_dummy") }

  let(:resolver_adapter) do
    described_class.new(
      api_key:           "sk_test_dummy",
      customer_resolver: ->(uid) { uid == "user-1" ? "cus_existing" : nil },
      customer_saver:    ->(_uid, _cid) {},
    )
  end

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

  # ── setup_url ────────────────────────────────────────────────────────────────

  describe "#setup_url" do
    it "creates a Checkout Session in setup mode for an existing customer and returns the url" do
      session = double("CheckoutSession", url: "https://checkout.stripe.com/setup/abc")

      # success_url is required by Stripe API even for hosted checkout.
      expect(::Stripe::Checkout::Session).to receive(:create).with(
        mode:                    "setup",
        customer:                "cus_existing",
        payment_method_types:    ["card"],
        success_url:             "http://localhost:3005/payment/return",
      ).and_return(session)

      url = resolver_adapter.setup_url(user_id: "user-1")
      expect(url).to eq("https://checkout.stripe.com/setup/abc")
    end

    it "creates a new Customer when none exists, persists the mapping, and returns the session url" do
      saved    = {}
      new_cus  = double("Customer", id: "cus_new")
      session  = double("CheckoutSession", url: "https://checkout.stripe.com/setup/xyz")

      fresh_adapter = described_class.new(
        api_key:           "***",
        customer_resolver: ->(_uid) { nil },
        customer_saver:    ->(uid, cid) { saved[uid] = cid },
      )

      expect(::Stripe::Customer).to receive(:create).with({ name: "principal-user-2" }).and_return(new_cus)
      expect(::Stripe::Checkout::Session).to receive(:create).with(
        hash_including(customer: "cus_new", mode: "setup", success_url: "http://localhost:3005/payment/return"),
      ).and_return(session)

      url = fresh_adapter.setup_url(user_id: "user-2")
      expect(url).to eq("https://checkout.stripe.com/setup/xyz")
      expect(saved["user-2"]).to eq("cus_new")
    end
  end

  # ── setup_required? ──────────────────────────────────────────────────────────

  describe "#setup_required?" do
    it "returns false when no customer resolver is configured (back-compat mode)" do
      # Without a resolver the adapter operates in explicit-PM / test-PM mode;
      # no SetupIntent check is performed.
      expect(adapter.setup_required?(user_id: "user-1")).to be false
    end

    it "returns true when the resolver returns nil (principal has no Customer yet)" do
      no_cus_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
      )
      expect(no_cus_adapter.setup_required?(user_id: "user-unknown")).to be true
    end

    it "returns true when the Customer exists but has no saved cards" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", invoice_settings: invoice_settings)
      pm_list          = double("PMList", data: [])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(resolver_adapter.setup_required?(user_id: "user-1")).to be true
    end

    it "returns false when the Customer has a saved default payment method" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_saved_123")
      customer         = double("Customer", invoice_settings: invoice_settings)

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

      expect(resolver_adapter.setup_required?(user_id: "user-1")).to be false
    end
  end

  # ── saved_method? ─────────────────────────────────────────────────────────

  describe "#saved_method?" do
    it "returns false when no customer resolver is configured" do
      expect(adapter.saved_method?(user_id: "user-1")).to be false
    end

    it "returns false when the resolver returns nil (unknown user)" do
      no_cus_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
      )
      expect(no_cus_adapter.saved_method?(user_id: "user-unknown")).to be false
    end

    it "returns true when the customer has a default_payment_method on invoice_settings" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_saved_123")
      customer         = double("Customer", invoice_settings: invoice_settings)

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

      expect(resolver_adapter.saved_method?(user_id: "user-1")).to be true
    end

    it "returns true when the customer has no default PM but has an attached card in the list" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", invoice_settings: invoice_settings)
      pm_item          = double("PM", id: "pm_attached_visa")
      pm_list          = double("PMList", data: [pm_item])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(resolver_adapter.saved_method?(user_id: "user-1")).to be true
    end

    it "returns false when the customer exists but has no saved cards" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", invoice_settings: invoice_settings)
      pm_list          = double("PMList", data: [])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(resolver_adapter.saved_method?(user_id: "user-1")).to be false
    end
  end

  # ── capture ──────────────────────────────────────────────────────────────────

  describe "#capture" do
    let(:pi) { double("PaymentIntent", id: "pi_123", amount_received: 1599, created: 1_700_000_000) }

    it "creates an off_session PaymentIntent using the explicit payment method (no customer resolver)" do
      expect(::Stripe::PaymentIntent).to receive(:create).with(
        {
          amount:         1599,
          currency:       "eur",
          payment_method: "pm_card_visa",
          off_session:    true,
          confirm:        true,
          metadata:       { cart_mandate_id: "cart-1" },
        },
        { idempotency_key: "cart-1-capture" },
      ).and_return(pi)

      result = adapter.capture(cart_mandate, payment_method: "pm_card_visa")

      expect(result[:psp_reference]).to eq("pi_123")
      expect(result[:settled_amount_cents]).to eq(1599)
      expect(result[:settled_at]).to eq(Time.at(1_700_000_000).utc)
    end

    it "falls back to the test payment method when payment_method is nil and no resolver is set" do
      expect(::Stripe::PaymentIntent).to receive(:create).with(
        hash_including(payment_method: "pm_card_visa", off_session: true),
        anything,
      ).and_return(pi)

      adapter.capture(cart_mandate, payment_method: nil)
    end

    it "raises SetupRequired when payment_method is nil and no test_payment_method is configured" do
      no_pm_adapter = described_class.new(api_key: "sk_test_dummy", test_payment_method: nil)
      expect {
        no_pm_adapter.capture(cart_mandate, payment_method: nil)
      }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end

    context "with a customer resolver" do
      it "charges the customer's default saved card off_session when no explicit pm is given" do
        invoice_settings = double("InvoiceSettings", default_payment_method: "pm_default_visa")
        customer         = double("Customer", invoice_settings: invoice_settings)

        allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
        expect(::Stripe::PaymentIntent).to receive(:create).with(
          {
            amount:         1599,
            currency:       "eur",
            customer:       "cus_existing",
            payment_method: "pm_default_visa",
            off_session:    true,
            confirm:        true,
            metadata:       { cart_mandate_id: "cart-1" },
          },
          { idempotency_key: "cart-1-capture" },
        ).and_return(pi)

        result = resolver_adapter.capture(cart_mandate, payment_method: nil)
        expect(result[:psp_reference]).to eq("pi_123")
      end

      it "falls back to the first listed card when no default PM is set" do
        invoice_settings = double("InvoiceSettings", default_payment_method: nil)
        customer         = double("Customer", invoice_settings: invoice_settings)
        pm_item          = double("PM", id: "pm_listed_visa")
        pm_list          = double("PMList", data: [pm_item])

        allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
        allow(::Stripe::PaymentMethod).to receive(:list).with(
          customer: "cus_existing", type: "card",
        ).and_return(pm_list)

        expect(::Stripe::PaymentIntent).to receive(:create).with(
          hash_including(customer: "cus_existing", payment_method: "pm_listed_visa"),
          anything,
        ).and_return(pi)

        resolver_adapter.capture(cart_mandate, payment_method: nil)
      end

      it "raises SetupRequired when the customer has no saved card" do
        invoice_settings = double("InvoiceSettings", default_payment_method: nil)
        customer         = double("Customer", invoice_settings: invoice_settings)
        pm_list          = double("PMList", data: [])

        allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
        allow(::Stripe::PaymentMethod).to receive(:list).with(
          customer: "cus_existing", type: "card",
        ).and_return(pm_list)

        expect {
          resolver_adapter.capture(cart_mandate, payment_method: nil)
        }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
      end

      it "raises SetupRequired when the resolver returns nil (unknown user)" do
        no_cus_adapter = described_class.new(
          api_key:           "sk_test_dummy",
          customer_resolver: ->(_uid) { nil },
        )
        expect {
          no_cus_adapter.capture(cart_mandate, payment_method: nil)
        }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
      end

      it "ignores an explicitly presented pm and charges the on-file card when a resolver is configured" do
        invoice_settings = double("InvoiceSettings", default_payment_method: "pm_default_visa")
        customer         = double("Customer", invoice_settings: invoice_settings)
        allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

        # In the SetupIntent model the assistant authorizes, never presents a
        # card — so a presented pm is ignored and the saved card is charged.
        expect(::Stripe::PaymentIntent).to receive(:create).with(
          hash_including(customer: "cus_existing", payment_method: "pm_default_visa"),
          anything,
        ).and_return(pi)

        resolver_adapter.capture(cart_mandate, payment_method: "pm_explicit")
      end
    end
  end

  # ── attach_test_card ──────────────────────────────────────────────────────

  describe "#attach_test_card" do
    it "saves the card via a SetupIntent and sets the attached pm as the default, returning the customer_id" do
      setup = double("SetupIntent", payment_method: "pm_attached_1")
      expect(::Stripe::SetupIntent).to receive(:create).with(
        hash_including(customer: "cus_existing", payment_method: "pm_card_visa", confirm: true, usage: "off_session"),
      ).and_return(setup)

      # The default is set to the SetupIntent's ATTACHED pm id, not the shared token.
      expect(::Stripe::Customer).to receive(:update).with(
        "cus_existing",
        { invoice_settings: { default_payment_method: "pm_attached_1" } },
      ).and_return(double("Customer"))

      result = resolver_adapter.attach_test_card(user_id: "user-1")
      expect(result).to eq("cus_existing")
    end

    it "creates a new customer when none exists and saves the mapping before the SetupIntent" do
      saved      = {}
      new_cus_id = "cus_created"
      new_cus    = double("Customer", id: new_cus_id)

      fresh_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
        customer_saver:    ->(uid, cid) { saved[uid] = cid },
      )

      expect(::Stripe::Customer).to receive(:create).with({ name: "principal-user-new" }).and_return(new_cus)
      setup = double("SetupIntent", payment_method: "pm_attached_2")
      expect(::Stripe::SetupIntent).to receive(:create).with(
        hash_including(customer: new_cus_id, payment_method: "pm_card_visa"),
      ).and_return(setup)
      expect(::Stripe::Customer).to receive(:update).with(
        new_cus_id,
        { invoice_settings: { default_payment_method: "pm_attached_2" } },
      ).and_return(double("Customer"))

      result = fresh_adapter.attach_test_card(user_id: "user-new")
      expect(result).to eq(new_cus_id)
      expect(saved["user-new"]).to eq(new_cus_id)
    end

    it "accepts a custom payment_method argument" do
      setup = double("SetupIntent", payment_method: "pm_attached_mc")
      allow(::Stripe::SetupIntent).to receive(:create).with(
        hash_including(customer: "cus_existing", payment_method: "pm_card_mastercard"),
      ).and_return(setup)
      allow(::Stripe::Customer).to receive(:update).and_return(double("Customer"))

      result = resolver_adapter.attach_test_card(user_id: "user-1", payment_method: "pm_card_mastercard")
      expect(result).to eq("cus_existing")
    end
  end
end
