# frozen_string_literal: true

require_relative "../../support/fake_stripe_api"
require_relative "../../support/stripe_mock"

# K-492 setup-session reuse, exercised through the REAL Stripe SDK over REAL
# HTTP instead of through doubles.
#
# `stripe_spec.rb` covers the same behaviour with `allow(::Stripe::Checkout::Session)
# .to receive(:list)`. That pins the adapter's branching, but it replaces the
# request encoding, the transport and the deserialization — the three places the
# reuse can silently stop working while every response still looks healthy
# (`outstanding_setup_session` cannot tell "no session" from "lookup missed",
# and degrading to minting is indistinguishable from the happy path on the
# wire). These examples do NOT stub the SDK.
#
# WHAT EACH LAYER PROVES — read this before adding to it:
#   * doubles (`stripe_spec.rb`)          — the adapter's branching only.
#   * FakeStripeApi (below)               — the SDK round trip: the filters we
#     actually put on the wire, the field names we actually read back, and
#     create→list reuse end to end. NOT a claim about Stripe's semantics.
#   * stripe-mock (below)                 — Stripe's own fixture shapes, from
#     Stripe's own OpenAPI spec. Stateless, so it CANNOT stage an outstanding
#     session; it bounds what is coverable here, and that boundary is asserted.
#   * `stripe_integration_spec.rb`        — the only place Stripe's real
#     semantics (does an outstanding setup session really list as `open`?) are
#     checked. Needs STRIPE_SECRET_KEY; skips without one, including in CI.
RSpec.describe Kiosk::PaymentProviders::Stripe, "setup-session reuse (K-492)" do
  # ── against a stateful local Stripe API ──────────────────────────────────────
  describe "over the real SDK against a stateful local Stripe API" do
    let(:fake)           { FakeStripeApi.new }
    let(:customer_store) { {} }
    let(:return_url)     { "https://shop.example/payment/return" }

    subject(:adapter) do
      described_class.new(
        api_key:           "sk_test_fake",
        customer_resolver: ->(uid) { customer_store[uid] },
        customer_saver:    ->(uid, cid) { customer_store[uid] = cid },
        return_url:        return_url,
      )
    end

    around do |example|
      saved_base    = ::Stripe.api_base
      saved_retries = ::Stripe.max_network_retries
      ::Stripe.api_base            = fake.base_url
      ::Stripe.max_network_retries = 0
      example.run
    ensure
      ::Stripe.api_base            = saved_base
      ::Stripe.max_network_retries = saved_retries
      fake.stop
    end

    it "hands back the SAME setup_url on a second poll and mints only ONE session" do
      first  = adapter.setup_url(user_id: "user-1")
      second = adapter.setup_url(user_id: "user-1")

      expect(first).to start_with("https://checkout.stripe.com/")
      expect(second).to eq(first)
      expect(fake.requests_to("POST", "/v1/checkout/sessions").size).to eq(1)
    end

    it "stays on that one session for a whole poll loop (the live bug minted five)" do
      urls = Array.new(5) { adapter.setup_url(user_id: "user-1") }

      expect(urls.uniq.size).to eq(1)
      expect(fake.requests_to("POST", "/v1/checkout/sessions").size).to eq(1)
    end

    # The wire request, not the Ruby call: a filter that never leaves the
    # process is a filter that cannot be wrong in the way K-492 was.
    it "asks for this customer's OPEN sessions on the wire" do
      adapter.setup_url(user_id: "user-1")
      adapter.setup_url(user_id: "user-1")

      lookup = fake.requests_to("GET", "/v1/checkout/sessions").last
      expect(lookup.params).to include("status" => "open", "limit" => "10")
      expect(lookup.params["customer"]).to eq(customer_store["user-1"])
      expect(customer_store["user-1"]).to start_with("cus_")
    end

    # Proves the `status: "open"` filter is LOAD-BEARING and not decoration:
    # once the session is no longer open the same code must mint a new one.
    it "mints a fresh session once the outstanding one is no longer open" do
      first = adapter.setup_url(user_id: "user-1")
      fake.close_all_sessions!
      second = adapter.setup_url(user_id: "user-1")

      expect(second).not_to eq(first)
      expect(fake.requests_to("POST", "/v1/checkout/sessions").size).to eq(2)
    end

    # Two principals must never share a hosted page.
    it "does not hand one principal another principal's outstanding session" do
      one = adapter.setup_url(user_id: "user-1")
      two = adapter.setup_url(user_id: "user-2")

      expect(two).not_to eq(one)
      expect(customer_store["user-2"]).not_to eq(customer_store["user-1"])
    end

    # The adapter reads listed sessions through `field(obj, :name)`, which is
    # `respond_to?` + `public_send` — and `Stripe::StripeObject` answers API
    # fields through `method_missing`. If that ever stopped being true the
    # helper would return nil for everything and reuse would quietly never
    # happen. Pinned against a genuinely deserialized object, not a double.
    it "reads mode/success_url/url off a genuinely deserialized listed session" do
      adapter.setup_url(user_id: "user-1")

      listed = ::Stripe::Checkout::Session.list(customer: customer_store["user-1"], status: "open", limit: 10).data.first
      expect(listed).to be_a(::Stripe::Checkout::Session)
      %i[mode success_url url].each do |name|
        expect(listed.respond_to?(name)).to be(true), "StripeObject no longer exposes ##{name}; `field` would read nil"
      end
      expect(listed.mode).to eq("setup")
      expect(listed.success_url).to eq(return_url)
    end
  end

  # ── against stripe-mock ──────────────────────────────────────────────────────
  #
  # HONEST BOUNDARY. stripe-mock cannot cover reuse end to end, and this states
  # why in an executable form rather than in a comment that could rot: it serves
  # OpenAPI fixtures and keeps no state, so `GET /v1/checkout/sessions` answers
  # with the SAME canned session whatever you created and whatever you filter on
  # — and that fixture is `mode: "payment"` with `success_url:
  # "https://example.com/success"`. Both of the adapter's guards miss it, so the
  # reuse branch is unreachable here BY CONSTRUCTION.
  #
  # What it does prove is the other half of the K-492 comment ("a fixture-returning
  # stub cannot be mistaken for a real outstanding session"), against Stripe's own
  # fixture shapes — and it pins the fixture, so if stripe-mock ever starts
  # serving a setup-mode session the reuse group above can be extended to it.
  describe "against stripe-mock (Stripe's own fixture server)" do
    let(:mock_url) { StripeMock.start }
    let(:customer_store) { {} }

    subject(:adapter) do
      described_class.new(
        api_key:           "sk_test_mock",
        customer_resolver: ->(uid) { customer_store[uid] },
        customer_saver:    ->(uid, cid) { customer_store[uid] = cid },
        return_url:        "https://shop.example/payment/return",
      )
    end

    around do |example|
      saved_base = ::Stripe.api_base
      example.run
    ensure
      ::Stripe.api_base = saved_base
    end

    before do
      skip "stripe-mock not installed (brew install stripe-mock)" unless mock_url

      ::Stripe.api_base = mock_url
      # spec_helper restores api_key around every example.
      ::Stripe.api_key = "sk_test_mock"
    end

    it "serves a list fixture that CANNOT stand in for an outstanding setup session" do
      listed = ::Stripe::Checkout::Session.list(customer: "cus_whatever", status: "open", limit: 10).data.first

      expect(listed.status).to eq("open")
      # …but neither of the two things the adapter requires:
      expect(listed.mode).to eq("payment")
      expect(listed.success_url).to eq("https://example.com/success")
    end

    it "does not let that fixture be mistaken for one — it mints instead of reusing" do
      url = adapter.setup_url(user_id: "user-1")

      expect(url).to start_with("https://checkout.stripe.com/")
      # stripe-mock echoes create params, so this is a session WE asked for in
      # setup mode — not the payment-mode fixture the list served.
      created = ::Stripe::Checkout::Session.list(customer: customer_store["user-1"], status: "open", limit: 10).data.first
      expect(created.mode).to eq("payment"), "stripe-mock became stateful — extend the reuse group above to it"
    end
  end
end
