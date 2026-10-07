# frozen_string_literal: true

require_relative "../../support/stripe_mock"

RSpec.describe Kiosk::PaymentProviders::Stripe do
  RETURN_URL  = "https://shop.example/kiosk/payment_setup/return"
  SUCCESS_URL = "#{RETURN_URL}?session_id={CHECKOUT_SESSION_ID}"

  subject(:adapter) do
    described_class.new(
      api_key:           "sk_test_dummy",
      customer_resolver: ->(uid) { uid == "user-1" ? "cus_existing" : nil },
      customer_saver:    ->(_uid, _cid) {},
    )
  end

  # The mapped customer exists at Stripe unless an example says otherwise.
  before do
    allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing")
      .and_return(double("Customer", id: "cus_existing"))
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

  # K-492: `setup_url` first asks Stripe whether an OPEN setup session is already
  # outstanding for the customer. Unless an example says otherwise, there is none.
  def stub_no_outstanding_session
    allow(::Stripe::Checkout::Session).to receive(:list).and_return(double("SessionList", data: []))
  end

  # A listed Checkout Session as the SDK would return it.
  def listed_session(mode: "setup", success_url: SUCCESS_URL,
                     url: "https://checkout.stripe.com/setup/OUTSTANDING")
    double("ListedSession", mode: mode, success_url: success_url, url: url)
  end

  describe "#setup_url" do
    before { stub_no_outstanding_session }

    it "creates a Checkout Session in setup mode for an existing customer and returns the url" do
      session = double("CheckoutSession", url: "https://checkout.stripe.com/setup/abc")

      # success_url is the engine's return page plus Stripe's session-id
      # placeholder; client_reference_id is how that page learns whose human it is.
      expect(::Stripe::Checkout::Session).to receive(:create).with(
        mode:                 "setup",
        customer:             "cus_existing",
        client_reference_id:  "user-1",
        payment_method_types: ["card"],
        success_url:          SUCCESS_URL,
      ).and_return(session)

      url = adapter.setup_url(user_id: "user-1", return_url: RETURN_URL)
      expect(url).to eq("https://checkout.stripe.com/setup/abc")
    end

    # K-473 (contract pin, not the confirmed root cause): a setup-mode session
    # created WITHOUT explicit payment_method_types falls onto Stripe's
    # dynamic-payment-methods path, which requires `currency` in setup mode;
    # omitting both yields a session whose hosted page errors. The shipped code
    # always passes `payment_method_types: ["card"]` (so `currency` is not
    # needed) — this pins that so a future regression dropping it is caught here
    # rather than on Stripe's hosted page.
    it "always pins explicit payment_method_types so setup mode needs no currency (K-473)" do
      session = double("CheckoutSession", url: "https://checkout.stripe.com/setup/abc")

      expect(::Stripe::Checkout::Session).to receive(:create) do |params|
        expect(params[:mode]).to eq("setup")
        expect(params[:payment_method_types]).to eq(["card"]),
          "setup-mode session must pin payment_method_types or Stripe requires `currency`"
        expect(params).to have_key(:success_url)
        session
      end

      adapter.setup_url(user_id: "user-1", return_url: RETURN_URL)
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
        hash_including(customer: "cus_new", mode: "setup", success_url: SUCCESS_URL),
      ).and_return(session)

      url = fresh_adapter.setup_url(user_id: "user-2", return_url: RETURN_URL)
      expect(url).to eq("https://checkout.stripe.com/setup/xyz")
      expect(saved["user-2"]).to eq("cus_new")
    end
  end

  describe "#setup_return_user_id" do
    it "answers the principal Stripe says the returned session was minted for" do
      allow(::Stripe::Checkout::Session).to receive(:retrieve).with("cs_1")
        .and_return(double("CheckoutSession", client_reference_id: "user-1"))
      expect(adapter.setup_return_user_id({ "session_id" => "cs_1" })).to eq("user-1")
    end

    it "answers nil without asking Stripe when the request names no session" do
      expect(::Stripe::Checkout::Session).not_to receive(:retrieve)
      expect(adapter.setup_return_user_id({})).to be_nil
    end
  end

  # ── setup_url is IDEMPOTENT across polls (K-492) ─────────────────────────────
  #
  # `payment_setup` is documented as the readiness probe an assistant POLLS while
  # its human is at the hosted page. Before this fix each poll called
  # Checkout::Session.create unconditionally, so the assistant held a NEW url
  # after every poll (5 sessions were minted for one live card setup) and
  # relaying the newest one dropped the human off the page they were filling in.
  describe "#setup_url reuse of an outstanding session (K-492)" do
    it "returns the OPEN setup session's url and mints NOTHING when one is outstanding" do
      expect(::Stripe::Checkout::Session).to receive(:list).with(
        customer: "cus_existing", status: "open", limit: 10,
      ).and_return(double("SessionList", data: [listed_session]))
      expect(::Stripe::Checkout::Session).not_to receive(:create)

      expect(adapter.setup_url(user_id: "user-1", return_url: RETURN_URL))
        .to eq("https://checkout.stripe.com/setup/OUTSTANDING")
    end

    it "returns the SAME url across repeated polls (the poll is side-effect-free)" do
      allow(::Stripe::Checkout::Session).to receive(:list)
        .and_return(double("SessionList", data: [listed_session]))
      allow(::Stripe::Checkout::Session).to receive(:create)

      urls = Array.new(5) { adapter.setup_url(user_id: "user-1", return_url: RETURN_URL) }

      expect(urls.uniq.size).to eq(1)
      expect(::Stripe::Checkout::Session).not_to have_received(:create)
    end

    it "mints a fresh session when the outstanding one targets a DIFFERENT success_url" do
      # An operator that re-pointed its origin must not hand the human a stale
      # return target.
      allow(::Stripe::Checkout::Session).to receive(:list).and_return(
        double("SessionList", data: [listed_session(success_url: "https://old-origin.example/kiosk/payment_setup/return?#{described_class::RETURN_QUERY}")]),
      )
      expect(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect(adapter.setup_url(user_id: "user-1", return_url: RETURN_URL))
        .to eq("https://checkout.stripe.com/setup/fresh")
    end

    it "ignores a listed session that is not in setup mode" do
      allow(::Stripe::Checkout::Session).to receive(:list).and_return(
        double("SessionList", data: [listed_session(mode: "payment")]),
      )
      expect(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect(adapter.setup_url(user_id: "user-1", return_url: RETURN_URL))
        .to eq("https://checkout.stripe.com/setup/fresh")
    end

    it "falls back to minting when the lookup itself fails (a probe must not start erroring)" do
      allow(::Stripe::Checkout::Session).to receive(:list)
        .and_raise(::Stripe::APIConnectionError.new("list timed out"))
      expect(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect(adapter.setup_url(user_id: "user-1", return_url: RETURN_URL))
        .to eq("https://checkout.stripe.com/setup/fresh")
    end

    # …and SAYS SO. Degrading to a fresh session is defensible; degrading to one
    # SILENTLY is not, because on the wire it is byte-for-byte the happy path —
    # a wrong filter, a renamed field or an API change would revert K-492 to a
    # session per poll and nothing anywhere would say a word. The log line is
    # the only difference between "no outstanding session" and "we never found out".
    it "SAYS SO when the lookup failed, so the degrade is not mistaken for the happy path" do
      allow(::Stripe::Checkout::Session).to receive(:list)
        .and_raise(::Stripe::APIConnectionError.new("list timed out"))
      allow(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect { adapter.setup_url(user_id: "user-1", return_url: RETURN_URL) }
        .to output(%r{could not list open setup sessions.*setup_url changes between polls}m).to_stderr
    end

    it "says NOTHING on the ordinary no-session path (the log line means a real fault)" do
      stub_no_outstanding_session
      allow(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect { adapter.setup_url(user_id: "user-1", return_url: RETURN_URL) }.not_to output.to_stderr
    end

    # The OTHER silent route to "no outstanding session": the lookup asks for one
    # page (SETUP_SESSION_LIST_LIMIT), so a principal sitting on that many open
    # Checkout Sessions can have the reusable one truncated off it. Rare, but on
    # the wire it is again byte-for-byte the happy path, so it is logged for the
    # same reason the failed lookup is.
    it "SAYS SO when a FULL page came back with nothing reusable in it" do
      full_page = Array.new(described_class::SETUP_SESSION_LIST_LIMIT) { listed_session(mode: "payment") }
      allow(::Stripe::Checkout::Session).to receive(:list)
        .and_return(double("SessionList", data: full_page))
      allow(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect { adapter.setup_url(user_id: "user-1", return_url: RETURN_URL) }
        .to output(/full page of #{described_class::SETUP_SESSION_LIST_LIMIT} open.*setup_url may change/m).to_stderr
    end

    it "stays quiet when a SHORT page came back with nothing reusable (nothing was truncated)" do
      short_page = Array.new(described_class::SETUP_SESSION_LIST_LIMIT - 1) { listed_session(mode: "payment") }
      allow(::Stripe::Checkout::Session).to receive(:list)
        .and_return(double("SessionList", data: short_page))
      allow(::Stripe::Checkout::Session).to receive(:create)
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect { adapter.setup_url(user_id: "user-1", return_url: RETURN_URL) }.not_to output.to_stderr
    end

  end

  # ── setup_required? ──────────────────────────────────────────────────────────

  describe "#setup_required?" do
    it "returns true when the resolver returns nil (principal has no Customer yet)" do
      no_cus_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
        customer_saver:    ->(_uid, _cid) {},
      )
      expect(no_cus_adapter.setup_required?(user_id: "user-unknown")).to be true
    end

    it "returns true when the Customer exists but has no saved cards" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
      pm_list          = double("PMList", data: [])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(adapter.setup_required?(user_id: "user-1")).to be true
    end

    it "returns false when the Customer has a saved default payment method" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_saved_123")
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

      expect(adapter.setup_required?(user_id: "user-1")).to be false
    end
  end

  # ── saved_method? ─────────────────────────────────────────────────────────

  describe "#saved_method?" do
    it "returns false when the resolver returns nil (unknown user)" do
      no_cus_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
        customer_saver:    ->(_uid, _cid) {},
      )
      expect(no_cus_adapter.saved_method?(user_id: "user-unknown")).to be false
    end

    it "returns true when the customer has a default_payment_method on invoice_settings" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_saved_123")
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

      expect(adapter.saved_method?(user_id: "user-1")).to be true
    end

    it "returns true when the customer has no default PM but has an attached card in the list" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
      pm_item          = double("PM", id: "pm_attached_visa")
      pm_list          = double("PMList", data: [pm_item])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(adapter.saved_method?(user_id: "user-1")).to be true
    end

    it "returns false when the customer exists but has no saved cards" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
      pm_list          = double("PMList", data: [])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect(adapter.saved_method?(user_id: "user-1")).to be false
    end
  end

  # ── capture ──────────────────────────────────────────────────────────────────

  describe "#capture" do
    let(:pi) { double("PaymentIntent", id: "pi_123", amount: 1599, created: 1_700_000_000) }

    it "charges the customer's default saved card off_session, keyed by the cart mandate id" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_default_visa")
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)

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

      result = adapter.capture(cart_mandate, payment_method: nil)
      expect(result[:psp_reference]).to eq("pi_123")
      expect(result[:settled_amount_cents]).to eq(1599)
    end

    it "falls back to the first listed card when no default PM is set" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
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

      adapter.capture(cart_mandate, payment_method: nil)
    end

    it "raises SetupRequired when the customer has no saved card" do
      invoice_settings = double("InvoiceSettings", default_payment_method: nil)
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
      pm_list          = double("PMList", data: [])

      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)
      allow(::Stripe::PaymentMethod).to receive(:list).with(
        customer: "cus_existing", type: "card",
      ).and_return(pm_list)

      expect {
        adapter.capture(cart_mandate, payment_method: nil)
      }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end

    it "raises SetupRequired when the resolver returns nil (unknown user)" do
      no_cus_adapter = described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(_uid) { nil },
        customer_saver:    ->(_uid, _cid) {},
      )
      expect {
        no_cus_adapter.capture(cart_mandate, payment_method: nil)
      }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end

    it "ignores an explicitly presented pm and charges the on-file card when a resolver is configured" do
      invoice_settings = double("InvoiceSettings", default_payment_method: "pm_default_visa")
      customer         = double("Customer", id: "cus_existing", invoice_settings: invoice_settings)
      allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing").and_return(customer)

      # In the SetupIntent model the assistant authorizes, never presents a
      # card — so a presented pm is ignored and the saved card is charged.
      expect(::Stripe::PaymentIntent).to receive(:create).with(
        hash_including(customer: "cus_existing", payment_method: "pm_default_visa"),
        anything,
      ).and_return(pi)

      adapter.capture(cart_mandate, payment_method: "pm_explicit")
    end

    it "settles the cart total against stripe-mock" do
      url = StripeMock.start
      skip "stripe-mock not installed (brew install stripe-mock)" unless url

      saved_base = ::Stripe.api_base
      ::Stripe.api_base = url
      allow(::Stripe::Customer).to receive(:retrieve).and_call_original
      receipt = adapter.capture(cart_mandate)
      expect(receipt[:psp_reference]).to start_with("pi_")
      expect(receipt[:settled_amount_cents]).to eq(1599)
    ensure
      ::Stripe.api_base = saved_base if saved_base
    end

    # ── PSP error translation (K-545) ────────────────────────────────────────
    # A charge failure must surface as a PSP-AGNOSTIC PaymentFailed carrying a
    # human-safe message (never raw Stripe internals) — so the executor renders
    # a typed `payment_failed` 402 instead of leaking a raw 500.
    context "when the charge fails at Stripe" do
      before do
        invoice_settings = double("InvoiceSettings", default_payment_method: "pm_default_visa")
        allow(::Stripe::Customer).to receive(:retrieve).with("cus_existing")
          .and_return(double("Customer", id: "cus_existing", invoice_settings: invoice_settings))
      end

      it "translates a Stripe::CardError (declined) into a RETRYABLE PaymentFailed with a safe message" do
        card_err = ::Stripe::CardError.new("Your card was declined.", nil, code: "card_declined")
        allow(::Stripe::PaymentIntent).to receive(:create).and_raise(card_err)

        expect { adapter.capture(cart_mandate) }
          .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
            expect(e).to be_retryable
            expect(e.reason).to eq(:card_declined)
            expect(e.message).to eq("the payment method was declined")
            # No raw Stripe text leaks through.
            expect(e.message).not_to match(/Your card was declined/)
          }
      end

      it "maps authentication_required to a distinct human-safe message (still retryable)" do
        card_err = ::Stripe::CardError.new("auth", nil, code: "authentication_required")
        allow(::Stripe::PaymentIntent).to receive(:create).and_raise(card_err)

        expect { adapter.capture(cart_mandate) }
          .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
            expect(e).to be_retryable
            expect(e.message).to match(/authentication/i)
          }
      end

      it "translates a non-card Stripe error (timeout/connectivity) into a NON-retryable PaymentFailed (unknown outcome)" do
        allow(::Stripe::PaymentIntent).to receive(:create)
          .and_raise(::Stripe::APIConnectionError.new("timed out"))

        expect { adapter.capture(cart_mandate) }
          .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
            expect(e).not_to be_retryable
            expect(e.reason).to eq(:processor_unavailable)
            expect(e.message).to match(/unknown/i)
            expect(e.message).not_to match(/timed out/)
          }
      end
    end
  end

  describe "#refund" do
    it "reverses the named PaymentIntent for the amount, keyed by the charge it undoes" do
      refund = double("Refund", id: "re_123", amount: 1599, created: 1_700_000_100)
      expect(::Stripe::Refund).to receive(:create).with(
        { payment_intent: "pi_123", amount: 1599 },
        { idempotency_key: "pi_123-refund" },
      ).and_return(refund)

      expect(adapter.refund(psp_reference: "pi_123", amount_cents: 1599)).to eq(
        psp_reference:          "re_123",
        refunded_psp_reference: "pi_123",
        refunded_amount_cents:  1599,
        refunded_at:            Time.at(1_700_000_100).utc,
      )
    end

    it "answers PaymentFailed when Stripe cannot refund, without Stripe's text" do
      allow(::Stripe::Refund).to receive(:create)
        .and_raise(::Stripe::InvalidRequestError.new("Charge ch_1 has already been refunded.", nil))

      expect { adapter.refund(psp_reference: "pi_123", amount_cents: 1599) }
        .to raise_error(Kiosk::PaymentProviders::PaymentFailed) { |e|
          expect(e.reason).to eq(:refund_failed)
          expect(e.message).not_to match(/ch_1/)
        }
    end

    it "refunds a charge against stripe-mock" do
      url = StripeMock.start
      skip "stripe-mock not installed (brew install stripe-mock)" unless url

      saved_base = ::Stripe.api_base
      ::Stripe.api_base = url
      receipt = adapter.refund(psp_reference: "pi_123", amount_cents: 1599)
      expect(receipt[:psp_reference]).to start_with("re_")
      expect(receipt[:refunded_psp_reference]).to eq("pi_123")
    ensure
      ::Stripe.api_base = saved_base if saved_base
    end
  end

  # ── a stored customer Stripe no longer knows (K-1993) ──────────────────────

  describe "with a stored customer Stripe no longer knows" do
    let(:store) { { "user-1" => "cus_gone" } }
    let(:stale_adapter) do
      described_class.new(
        api_key:           "sk_test_dummy",
        customer_resolver: ->(uid) { store[uid] },
        customer_saver:    ->(uid, cid) { store[uid] = cid },
      )
    end

    before do
      allow(::Stripe::Customer).to receive(:retrieve).with("cus_gone")
        .and_raise(::Stripe::InvalidRequestError.new("No such customer: 'cus_gone'", "id", code: "resource_missing"))
    end

    it "requires setup" do
      expect(stale_adapter.setup_required?(user_id: "user-1")).to be true
    end

    it "mints a fresh customer for the setup page and saves it in place of the stale one" do
      stub_no_outstanding_session
      allow(::Stripe::Customer).to receive(:create).and_return(double("Customer", id: "cus_fresh"))
      expect(::Stripe::Checkout::Session).to receive(:create).with(hash_including(customer: "cus_fresh"))
        .and_return(double("CheckoutSession", url: "https://checkout.stripe.com/setup/fresh"))

      expect(stale_adapter.setup_url(user_id: "user-1", return_url: RETURN_URL))
        .to eq("https://checkout.stripe.com/setup/fresh")
      expect(store["user-1"]).to eq("cus_fresh")
    end

    it "refuses a charge with SetupRequired" do
      expect { stale_adapter.capture(cart_mandate) }.to raise_error(Kiosk::PaymentProviders::SetupRequired)
    end

    it "treats a deleted customer the same way" do
      allow(::Stripe::Customer).to receive(:retrieve).with("cus_gone")
        .and_return(::Stripe::Customer.construct_from(id: "cus_gone", deleted: true))
      expect(stale_adapter.setup_required?(user_id: "user-1")).to be true
    end

    it "still raises any other Stripe error" do
      allow(::Stripe::Customer).to receive(:retrieve).with("cus_gone")
        .and_raise(::Stripe::APIConnectionError.new("timed out"))
      expect { stale_adapter.setup_required?(user_id: "user-1") }.to raise_error(::Stripe::APIConnectionError)
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

      result = adapter.attach_test_card(user_id: "user-1")
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

      result = adapter.attach_test_card(user_id: "user-1", payment_method: "pm_card_mastercard")
      expect(result).to eq("cus_existing")
    end
  end
end
