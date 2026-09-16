# frozen_string_literal: true

# Real Stripe test-mode round-trip. Skipped unless STRIPE_SECRET_KEY is set
# (an sk_test_… key). Never moves real money.
#
# ── THE KEY RULE, AND IT IS THE MAINTAINER'S, NOT A PREFERENCE (T-207) ───────
#
# A real Stripe key MUST NOT reach an automated test, and this file is the one
# a later session will be tempted to feed. There IS a live sk_test_ key on the
# maintainer's machine, in getgrocery's gitignored `mise.toml`; the ruling is
# to leave it alone. Three clauses, all three binding:
#
#   1. The real key is never used by an automated test. If it is in your shell
#      — mise exports it inside the getgrocery tree — unset it before running
#      this suite rather than letting the skip above turn into a live call.
#   2. `stripe-mock` is the test double. It is Stripe's own fixture server, it
#      is what the group in stripe_setup_reuse_spec.rb drives, and it is what
#      the demo tasks self-start when no key is set.
#   3. The key is not copied to another demo. Only getgrocery wires the Stripe
#      adapter at all; the other operator demos resolve a placeholder and take
#      no money.
#
# The question this file exists to answer — does a saved card survive, so a
# returning customer is not asked for it twice — is ANSWERED, by the
# maintainer's own hand-driven verification rather than by a run here: repeat
# payment works and the card details are retained. A re-check against the live
# API is owed after 0.4 ships, and until then this file's skip is the correct
# outcome rather than a gap.
#
# NOTE: real `pi_…` verification needs the operator's test key. Without it,
# these examples are skipped. The mocked suite (stripe_spec.rb) runs without
# a key and covers the adapter's public methods with plain RSpec doubles
# (no WebMock — the SDK classes are stubbed directly).
RSpec.describe Kiosk::PaymentProviders::Stripe, :integration do
  before do |example|
    next if example.metadata[:no_key_needed]

    skip "set STRIPE_SECRET_KEY (sk_test_…) to run" unless ENV["STRIPE_SECRET_KEY"]
  end

  # In-memory principal→customer store (replaces the app's stripe_customers table).
  let(:customer_store) { {} }

  # `return_url:` is not optional here. A hosted SetupIntent with no resolvable
  # success_url fails LOUD before any Stripe call, and this adapter is built
  # outside a configured Kiosk host, so `Kiosk.configuration.issuer` is nil and
  # there is nothing to derive one from. Without it both `#setup_url` examples
  # below raise instead of running — and a raise inside a file that skips
  # without a key is invisible, which is how they went unrun.
  subject(:adapter) do
    described_class.new(
      api_key:           ENV["STRIPE_SECRET_KEY"],
      customer_resolver: ->(uid) { customer_store[uid] },
      customer_saver:    ->(uid, cid) { customer_store[uid] = cid },
      return_url:        "https://shop.example/payment/return",
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

  # The ONE example in this file that does not skip, and the only reason the
  # rest can be trusted to fail for Stripe's reasons rather than for ours: a
  # subject that raises before any network call is indistinguishable from a
  # skip, and a skip is the same colour as a pass. It touches no network.
  describe "the subject itself" do
    it "resolves a success_url without reaching Stripe", :no_key_needed do
      expect(adapter.send(:resolved_return_url)).to eq("https://shop.example/payment/return")
    end
  end

  describe "#attach_test_card + #capture (full off_session round-trip)" do
    it "attaches a test card then captures a real test payment" do
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
    end
  end

  describe "#setup_url" do
    it "returns a hosted Stripe Checkout URL for the setup flow" do
      url = adapter.setup_url(user_id: user_id)
      expect(url).to start_with("https://checkout.stripe.com/")
    end

    # K-492 against the real API. This is the ONLY example anywhere that can
    # answer the question the reuse rests on: does a just-created `mode:setup`
    # Checkout Session actually come back from `list(status: "open")`? The
    # double-based specs and the local stateful fake in
    # `stripe_setup_reuse_spec.rb` both ASSUME it — they exercise our side of
    # the contract, not Stripe's. Needs STRIPE_SECRET_KEY; CI deliberately has
    # none, so in CI this is skipped, not passed.
    it "returns the SAME url on a second call and leaves exactly ONE open setup session (K-492)" do
      first  = adapter.setup_url(user_id: user_id)
      second = adapter.setup_url(user_id: user_id)

      expect(second).to eq(first)

      cus_id     = customer_store[user_id]
      open_setup = ::Stripe::Checkout::Session
                   .list(customer: cus_id, status: "open", limit: 10)
                   .data.select { |s| s.mode == "setup" }
      expect(open_setup.map(&:url)).to eq([first])
    end
  end

  describe "#saved_method? before card setup" do
    it "returns false for a new user with no card on file" do
      fresh_user = "no-card-user-#{Process.pid}"
      expect(adapter.saved_method?(user_id: fresh_user)).to be false
    end
  end
end
