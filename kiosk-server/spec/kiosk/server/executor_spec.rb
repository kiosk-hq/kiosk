# frozen_string_literal: true

RSpec.describe Kiosk::Server::Executor do
  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: "agent") }

  describe ".call construction" do
    it "raises Unauthenticated when identity is nil" do
      expect {
        described_class.call(kind: :run, args: {}, name: "ping", identity: nil, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /identity/)
    end

    it "raises BadRequest for an unknown verb" do
      expect {
        described_class.call(kind: :wat, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest) { |e|
        expect(e.hint).to include("query")
      }
    end
  end

  describe "transaction discipline" do
    it "wraps the verb in a single transaction with GUCs set" do
      declare_query("probe") { render json: [{ ok: 1 }] }
      described_class.call(kind: :query, args: {}, name: "probe", identity: identity, connection: connection)

      # 4 GUC statements only (the handler renders rows without hitting
      # connection). They are `set_config` binds since K-789, so the GUC name
      # is the first bind rather than part of the statement text.
      gucs = connection.bound(/set_config/)
      expect(gucs.size).to eq(4)
      expect(gucs.first.last.first).to eq("app.current_user_id")
      expect(gucs.last.last.first).to eq("app.current_agent_id")
      expect(connection.executed_sql).to be_empty
      expect(connection.in_transaction?).to be(false) # closed after call
    end
  end

  describe "verb :query" do
    before do
      declare_query("menu") { render json: [{ "id" => 1, "name" => "Margherita" }] }
    end

    it "looks up the query by name and returns :rows Result" do
      result = described_class.call(
        kind: :query, args: {}, name: "menu",
        identity: identity, connection: connection,
      )

      expect(result).to be_a(Kiosk::Server::Result)
      expect(result.kind).to    eq(:rows)
      expect(result.payload).to eq([{ "id" => 1, "name" => "Margherita" }])
    end

    it "passes params (args minus name) to the query handler" do
      declare_query("items") { render json: [{ filter: params[:category] }] }
      result = described_class.call(
        kind: :query, args: { category: "pizza" }, name: "items",
        identity: identity, connection: connection,
      )
      # String keys: a handler RENDERS, so the row makes a JSON round trip
      # before the Executor sees it — which is what reaches the agent.
      expect(result.payload).to eq([{ "filter" => "pizza" }])
    end

    it "raises BadRequest when name is missing" do
      expect {
        described_class.call(kind: :query, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /name/)
    end

    it "raises NotFound when the query isn't registered" do
      expect {
        described_class.call(kind: :query, args: {}, name: "missing",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::NotFound)
    end

    it "lets Kiosk::Server::Errors raised inside the query propagate unchanged" do
      declare_query("denied") { raise Kiosk::Server::Errors::RLSDenied, "no" }

      expect {
        described_class.call(kind: :query, args: {}, name: "denied",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end

    it "wraps StandardError raised inside the query as ActionFailed" do
      declare_query("boom") { raise "kaboom" }

      expect {
        described_class.call(kind: :query, args: {}, name: "boom",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed, /kaboom/)
    end

    # ── cursor pagination seam (ADR-0021 / T-042) ─────────────────────────

    it "leaves next_cursor nil when the handler returns a bare Array (back-compat)" do
      declare_query("flat") { render json: [{ "id" => 1 }, { "id" => 2 }] }
      result = described_class.call(kind: :query, args: {}, name: "flat",
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ "id" => 1 }, { "id" => 2 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_payload).to be_an(Array)  # a bare array, like every query
    end

    # T-092: the cursor reaches the RESULT, never the body. The wire turns it
    # into `Link: …; rel="next"`; the Executor's job ends at carrying it.
    it "threads a Page's next_cursor and total onto the Result, not into the body" do
      declare_query("paged") do
        offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
        render_kiosk_page([{ "id" => offset + 1 }],
                          next_cursor: Kiosk::Server::Cursor.encode_offset(offset + 1),
                          total:       42)
      end

      result = described_class.call(kind: :query, args: { limit: 1 }, name: "paged",
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ "id" => 1 }])
      expect(result.next_cursor).to eq(Kiosk::Server::Cursor.encode_offset(1))
      expect(result.total).to       eq(42)
      expect(result.to_payload).to  eq([{ "id" => 1 }])
    end

    it "omits `next` when a paginating handler signals the last page (Page with nil cursor)" do
      declare_query("last") do
        render_kiosk_page([{ "id" => 99 }]) # no next_cursor => complete
      end
      result = described_class.call(kind: :query, args: {}, name: "last",
                                    identity: identity, connection: connection)

      expect(result.payload).to     eq([{ "id" => 99 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_payload).to be_an(Array)  # a bare array, like every query
    end
  end

  describe "verb :run" do
    before do
      declare_action("ping") { render json: { pong: params[:greeting] } }
    end

    it "looks up the action by name and calls it with sym-keyed args" do
      result = described_class.call(
        kind: :run, args: { greeting: "world" }, name: "ping",
        identity: identity, connection: connection,
      )

      expect(result.kind).to    eq(:value)
      # String keys: the handler renders, so the value makes a JSON round trip.
      expect(result.payload).to eq("pong" => "world")
    end

    it "passes through args (except name) to the action handler" do
      declare_action("echo") { render json: { a: params[:a], b: params[:b] } }
      result = described_class.call(
        kind: :run, args: { a: 1, b: "x" }, name: "echo",
        identity: identity, connection: connection,
      )
      expect(result.payload).to eq("a" => 1, "b" => "x")
    end

    it "raises BadRequest when name is missing" do
      expect {
        described_class.call(kind: :run, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /name/)
    end

    it "raises NotFound when the action isn't registered" do
      expect {
        described_class.call(kind: :run, args: {}, name: "missing",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::NotFound)
    end

    it "lets Kiosk::Server::Errors raised inside the action propagate unchanged" do
      declare_action("denied") { raise Kiosk::Server::Errors::RLSDenied, "no" }

      expect {
        described_class.call(kind: :run, args: {}, name: "denied",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end

    it "wraps StandardError raised inside the action as ActionFailed" do
      declare_action("boom") { raise "kaboom" }

      expect {
        described_class.call(kind: :run, args: {}, name: "boom",
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed, /kaboom/)
    end
  end

  # The `events` verb was removed (never a capability). It is
  # now an unknown verb → a clean 400 BadRequest, not a raw NotImplementedError.
  describe "removed :events verb" do
    it "is rejected as an unknown verb (clean BadRequest, not NotImplementedError)" do
      expect {
        described_class.call(kind: :events, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb/)
    end
  end

  # ── `:schema` LEFT THIS DISPATCHER (T-094) ────────────────────────────
  #
  # `GET <endpoint>/schema` is PUBLIC now: it resolves no identity, and an
  # Executor cannot be built without one. The catalog it used to render lives
  # in {Kiosk::Server::SchemaDocument}, derived at boot and specced next door
  # in schema_document_spec.rb. What stays here is the pair of facts that keep
  # the two vocabularies honest.
  describe "verb :schema (no longer dispatchable)" do
    it "is refused as an unknown verb, with the valid three named" do
      expect {
        described_class.call(kind: :schema, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb: :schema/)
    end

    # And it is no longer a POLICY verb either. `POLICY_VERBS` existed for one
    # caller — `/kiosk/openapi.json`, tolled as `:schema` while it was still
    # Bearer-gated. K-804 made that endpoint public, nothing tolls as
    # `:schema`, and a constant that was a byte-identical copy of {VERBS}
    # under another name was deleted rather than left as documentation.
    it "is gone from the vocabulary entirely — one list, not two" do
      expect(described_class::VERBS).to eq(%i[query run pay])
      expect(described_class.const_defined?(:POLICY_VERBS)).to be(false)
    end
  end

  describe "verb :help (removed)" do
    it "is no longer a recognised verb" do
      expect {
        described_class.call(kind: :help, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /Unknown verb/)
    end
  end

  describe "verb :pay" do
    let(:identity) { build_identity(agent_id: "a-1") }
    let(:intent) do
      Kiosk::Mandate::IntentMandate.new(
        id: "intent-1", user_id: "u-1", agent_id: "a-1", issuer: "https://demo.example",
        scope: "groceries", cap_amount_cents: 5000, currency: "eur",
        expires_at: nil, created_at: nil, raw_jws: "intent-jws",
      )
    end
    let(:cart) do
      Kiosk::Mandate::CartMandate.new(
        id: "cart-1", intent_mandate_id: "intent-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://demo.example", line_items: [{ sku: "pizza", qty: 1 }],
        total_amount_cents: 1599, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart-jws",
      )
    end
    let(:payment) do
      Kiosk::Mandate::PaymentMandate.new(
        id: "pay-1", cart_mandate_id: "cart-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://demo.example", payment_method: "pm_card_visa",
        amount_cents: 1599, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "payment-jws",
      )
    end
    let(:settlement) { { psp_reference: "pi_1", settled_amount_cents: 1599, settled_at: Time.now } }
    let(:valid_args) do
      { intent_mandate_jws: "intent-jws", cart_mandate_jws: "cart-jws", payment_mandate_jws: "payment-jws" }
    end

    before do
      Kiosk.reset!
      Kiosk.configure { |c| c.issuer = "https://demo.example" }
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent)
        .with(raw_jws: "intent-jws", identity: identity).and_return(intent)
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart)
        .with(raw_jws: "cart-jws", identity: identity, intent: intent).and_return(cart)
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment)
        .with(raw_jws: "payment-jws", identity: identity, cart: cart).and_return(payment)
      # Persist helpers return SERVER-generated ids (uuid PKs); the verb
      # threads them through the FK chain.
      allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
        .and_return("intent-row")
      allow_any_instance_of(described_class).to receive(:persist_cart_mandate)
        .and_return("cart-row")
      allow_any_instance_of(described_class).to receive(:persist_payment_mandate)
        .and_return("pay-row")
      allow_any_instance_of(described_class).to receive(:persist_settlement)
        .and_return("s-1")
      Kiosk.configuration.payment_provider = instance_double("PSP", capture: settlement, setup_required?: false)
    end

    it "verifies the trail, captures, and returns the full settlement payload" do
      result = described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      expect(result.kind).to eq(:value)
      expect(result.payload).to include(
        settlement_id:        "s-1",
        psp_reference:        "pi_1",
        settled_amount_cents: 1599,
        currency:             "eur",
      )
    end

    context "per-assistant spending cap" do
      it "does not enforce when no spending_cap seam is configured (default)" do
        expect_any_instance_of(described_class).not_to receive(:settled_total_cents)
        expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      end

      it "does not enforce for an assistant the seam reports uncapped (nil)" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { nil }
        expect_any_instance_of(described_class).not_to receive(:settled_total_cents)
        expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      end

      it "proceeds when spent + cart total is within the cap" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { 5000 }
        allow_any_instance_of(described_class).to receive(:settled_total_cents).and_return(1000) # +1599 = 2599 <= 5000
        expect(Kiosk.configuration.payment_provider).to receive(:capture).and_return(settlement)
        result = described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        expect(result.kind).to eq(:value)
      end

      it "rejects with SpendingCapExceeded (403) and does NOT capture when the cap would be exceeded" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { 2000 }
        allow_any_instance_of(described_class).to receive(:settled_total_cents).and_return(1000) # +1599 = 2599 > 2000
        expect(Kiosk.configuration.payment_provider).not_to receive(:capture)
        expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
          .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded) { |e| expect(e.http_status).to eq(403) }
      end

      it "treats a cap of 0 as disabled (any charge rejected)" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { 0 }
        allow_any_instance_of(described_class).to receive(:settled_total_cents).and_return(0)
        expect(Kiosk.configuration.payment_provider).not_to receive(:capture)
        expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
          .to raise_error(Kiosk::Server::Errors::SpendingCapExceeded)
      end

      it "passes the acting agent_id, window, and cart currency to the settled-total query" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { 5000 }
        Kiosk.configuration.spending_cap_window_days = 7
        expect_any_instance_of(described_class).to receive(:settled_total_cents)
          .with(agent_id: "a-1", window_days: 7, currency: "eur").and_return(0)
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      end

      # K-551: the tally must be scoped to the cart's currency — summing cents
      # across currencies is meaningless (4999 USD is not within a 5000 EUR cap),
      # and a cross-currency sum could erode the cap. The cart here is EUR.
      it "scopes the settled-total tally to the cart's currency (not currency-blind)" do
        Kiosk.configuration.spending_cap = ->(agent_id:) { 5000 }
        expect_any_instance_of(described_class).to receive(:settled_total_cents)
          .with(hash_including(currency: "eur")).and_return(0)
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      end
    end

    it "threads the SERVER-generated intent id into the cart persist (FK chain, not the signed id)" do
      expect_any_instance_of(described_class).to receive(:persist_cart_mandate)
        .with(cart, intent_row_id: "intent-row").and_return("cart-row")
      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
    end

    it "threads the SERVER-generated cart id into the payment mandate persist (FK chain)" do
      expect_any_instance_of(described_class).to receive(:persist_payment_mandate)
        .with(cart_row_id: "cart-row", payment: payment).and_return("pay-row")
      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
    end

    it "threads the SERVER-generated cart id into the settlement persist (FK chain)" do
      expect_any_instance_of(described_class).to receive(:persist_settlement)
        .with(cart_row_id: "cart-row", cart: cart, settled: settlement).and_return("s-1")
      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
    end

    it "passes the assistant-presented payment_method to capture" do
      expect(Kiosk.configuration.payment_provider).to receive(:capture)
        .with(cart, payment_method: "pm_card_visa").and_return(settlement)
      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
    end

    # N2: a unique-violation surfacing from phase-1 persistence (same signed
    # mandate replayed) is a 409 Conflict, not a 500. Matched by class NAME so
    # the gem needn't load ActiveRecord in its own unit env.
    it "maps a phase-1 unique violation to Errors::Conflict (409)" do
      stub_const("ActiveRecord::RecordNotUnique", Class.new(StandardError))
      allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
        .and_raise(ActiveRecord::RecordNotUnique.new("dup key"))
      # K-850: the violation alone no longer decides the answer — the executor
      # asks whether THIS chain already settled. Here nothing did (the insert
      # never ran), so the settled-replay lookup finds no row and the 409 the
      # example is about is the one that reaches the caller.
      connection.next_exec_result = []

      expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Conflict) { |e| expect(e.http_status).to eq(409) }
    end

    it "lets a non-unique phase-1 error propagate unchanged (not remapped to Conflict)" do
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart)
        .and_raise(Kiosk::Server::Errors::Forbidden.new("cart exceeds intent cap"))

      expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /cap/)
    end

    # An agentless principal (user_idp web/mobile session, agent_id nil)
    # cannot pay — mandates are agent-signed. Reject with a clean
    # 403, not a 500 from agent_payment_key(nil) deep in mandate verification.
    it "rejects an agentless caller (agent_id nil) with a clean 403 before verifying mandates" do
      agentless = build_identity(actor: "human", agent_id: nil)
      expect(Kiosk::Server::MandateVerifier).not_to receive(:verify_intent)

      expect { described_class.call(kind: :pay, args: valid_args, identity: agentless, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /agent identity/) { |e| expect(e.http_status).to eq(403) }
    end

    it "does not capture when phase-1 persistence raises a unique violation" do
      stub_const("ActiveRecord::RecordNotUnique", Class.new(StandardError))
      allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
        .and_raise(ActiveRecord::RecordNotUnique.new("dup key"))
      connection.next_exec_result = [] # no settlement for this chain (K-850)
      provider = Kiosk.configuration.payment_provider
      expect(provider).not_to receive(:capture)

      expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Conflict)
    end

    # C2: an irreversible PSP capture must never run inside a DB transaction —
    # a ROLLBACK cannot undo a Stripe charge. FakeConnection tracks tx depth.
    it "captures OUTSIDE any DB transaction" do
      in_tx_at_capture = nil
      Kiosk.configuration.payment_provider = instance_double("PSP")
      allow(Kiosk.configuration.payment_provider).to receive(:setup_required?).and_return(false)
      allow(Kiosk.configuration.payment_provider).to receive(:capture) do |_cart, **_kwargs|
        in_tx_at_capture = connection.in_transaction?
        settlement
      end

      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      expect(in_tx_at_capture).to be(false)
    end

    # I-1: provider.setup_required? == true → clean 402 BEFORE Phase 1 persists
    # anything.  No mandate ids are burned, so the agent can retry after the
    # human completes the SetupIntent flow without hitting the UNIQUE idempotency key.
    it "raises PaymentSetupRequired (402) before persisting mandates when provider.setup_required? is true" do
      provider = instance_double("PSP", setup_required?: true)
      Kiosk.configuration.payment_provider = provider

      # Phase 1 mandate verification must not run — no mandate burning.
      expect(Kiosk::Server::MandateVerifier).not_to receive(:verify_intent)

      expect {
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::PaymentSetupRequired) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq("payment_setup_required")
      }
    end

    # I-1 belt-and-suspenders: if a card is detached between the pre-check and
    # capture (race), the PSP raises SetupRequired and we re-raise it cleanly.
    it "re-raises a capture-time SetupRequired as PaymentSetupRequired (402)" do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::SetupRequired)

      expect {
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::PaymentSetupRequired) { |e|
        expect(e.http_status).to eq(402)
      }
    end

    # K-545: a card DECLINE (retryable PaymentFailed) becomes a typed
    # `payment_failed` 402, NOT a raw 500. The mandate trail is already
    # persisted; the message is the adapter's human-safe string (no PSP
    # internals) and the hint tells the agent it is safe to retry.
    it "maps a retryable capture-time PaymentFailed to Errors::PaymentFailed (402, payment_failed)" do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new(
                     "the payment method was declined", reason: :card_declined, retryable: true))

      expect {
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq("payment_failed")
        expect(e.message).to     eq("the payment method was declined")
        expect(e.hint).to        match(/no money moved|update the payment method/i)
      }
    end

    # K-545: an UNKNOWN outcome (timeout / connectivity — non-retryable
    # PaymentFailed) is also a typed 402, but its hint steers the agent to check
    # my_orders BEFORE retrying so a lost-response retry can't double-charge.
    it "maps a non-retryable capture-time PaymentFailed to a 402 whose hint warns against a blind retry" do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new(
                     "the payment processor could not confirm the charge; its status is unknown",
                     reason: :processor_unavailable, retryable: false))

      expect {
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
        expect(e.http_status).to eq(402)
        expect(e.code).to        eq("payment_failed")
        expect(e.hint).to        match(/my_orders/i)
      }
    end

    # K-851: the UNKNOWN hint used to end "retry only if it is still unpaid" —
    # which reads a MISSING settlement record as proof that no money moved. It
    # is not proof: the engine records the settlement in P3, AFTER the capture,
    # so inside that window an operator's own records show an order that has
    # already been charged as unpaid. An assistant that took the old sentence
    # literally re-signed a fresh chain, drew a fresh cart id, drew a fresh PSP
    # idempotency key, and charged its human twice. protocol.md §11.6 now
    # requires a POSITIVE "not paid" before re-signing, and this pins the hint
    # to that rule rather than to "still unpaid".
    it "tells the agent to retry only on a POSITIVE not-paid, never on a missing record (K-851)" do
      allow(Kiosk.configuration.payment_provider).to receive(:capture)
        .and_raise(Kiosk::PaymentProviders::PaymentFailed.new(
                     "the payment processor could not confirm the charge; its status is unknown",
                     reason: :processor_unavailable, retryable: false))

      expect {
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::PaymentFailed) { |e|
        expect(e.hint).to     match(/positive .?not paid.?/i)
        expect(e.hint).to     match(/missing or pending record is not/i)
        expect(e.hint).to     match(/stop and tell your human/i)
        expect(e.hint).not_to match(/retry only if it is still unpaid/i)
      }
    end

    it "raises BadRequest when intent_mandate_jws is missing" do
      expect {
        described_class.call(kind: :pay,
          args: { cart_mandate_jws: "cart-jws", payment_mandate_jws: "payment-jws" },
          identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /intent_mandate_jws/)
    end

    it "raises BadRequest when cart_mandate_jws is missing" do
      expect {
        described_class.call(kind: :pay,
          args: { intent_mandate_jws: "intent-jws", payment_mandate_jws: "payment-jws" },
          identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /cart_mandate_jws/)
    end

    it "raises BadRequest when payment_mandate_jws is missing" do
      expect {
        described_class.call(kind: :pay,
          args: { intent_mandate_jws: "intent-jws", cart_mandate_jws: "cart-jws" },
          identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /payment_mandate_jws/)
    end

    it "raises Forbidden when no payment_provider is configured" do
      Kiosk.configuration.payment_provider = nil
      expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /payment_provider/)
    end

    # K-800: THE ORIGIN ANSWERS BEFORE THE ARGUMENTS DO. `pay` is drawn on every
    # mounted host — {Engine}'s route comment says a host with no
    # payment_provider "answers it with the wire's own 403" — but the three
    # mandate guards used to run first, so an empty POST at a payment-free
    # origin came back `400 args.intent_mandate_jws required`: an instruction to
    # sign three mandates, from an origin that could never settle them. The
    # example sends NO arguments at all, which is exactly the case the old order
    # got wrong.
    it "answers a payment-free origin with the 403 even when NO mandates are sent (K-800)" do
      Kiosk.configuration.payment_provider = nil
      expect { described_class.call(kind: :pay, args: {}, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /no payment_provider configured/)
    end

    # ── Replay: the mandate chain IS the idempotency key (K-739) ───────────
    #
    # `pay` publishes no idempotency header and no idempotency field, and the
    # spec (protocol.md §11.6) now says why it needs none: the three mandate
    # `id`s already are one, and an assistant whose `pay` response was lost
    # retries with the IDENTICAL chain. These examples pin BOTH halves of the
    # behaviour that claim rests on — the safe path and the unsafe one — at the
    # only layer where "how many times was the card charged" is observable
    # without a database.
    #
    # The persist helpers run FOR REAL here (the enclosing `before` stubs them;
    # this context calls them through) against a router that enforces the
    # constraint the shipped schema declares: `UNIQUE (user_id, mandate_id)` on
    # each of the three mandate tables. So the 409 is produced by the same
    # `unique_violation?` remap a real Postgres would trip, not by a stub.
    context "replayed with the identical mandate chain" do
      # `[table, mandate_id]` for every mandate row the router has accepted —
      # the in-memory stand-in for `UNIQUE (user_id, mandate_id)`. One
      # principal per example, so the mandate id alone is the whole key.
      let(:inserted) { [] }
      let(:captures) { [] }
      # The rows those inserts wrote, by table, each as a column=>value hash
      # plus the server id the statement returned. K-850's replay lookup is a
      # READ, so a router that answers it has to have kept what was written.
      let(:stored) { Hash.new { |h, k| h[k] = [] } }

      # The INSERT column order of the four persist helpers, so a recorded row
      # reads by name instead of by bind index.
      insert_columns = {
        "intent_mandates"  => %w[mandate_id user_id agent_id issuer scope cap_amount_cents
                                 currency expires_at raw_jws],
        "cart_mandates"    => %w[mandate_id intent_mandate_id user_id agent_id issuer line_items
                                 total_amount_cents currency expires_at raw_jws],
        "payment_mandates" => %w[mandate_id cart_mandate_id user_id agent_id issuer payment_method
                                 amount_cents currency expires_at raw_jws],
        "settlements"      => %w[cart_mandate_id user_id agent_id issuer psp_reference
                                 settled_amount_cents currency],
      }.freeze

      # {Executor#settlement_for_chain}'s meaning, evaluated over the recorded
      # rows: the cart matched by (user_id, mandate_id, raw_jws), its intent and
      # payment matched by the FK chain AND their own raw_jws, and finally the
      # settlement of that cart. Every one of those conjuncts is load-bearing —
      # drop the raw_jws comparisons and a mandate id re-used with different
      # content would be handed a settlement it did not buy.
      def settled_chain_rows(stored, binds)
        user_id, cart_mandate_id, cart_jws, intent_jws, payment_jws = binds

        cart = stored["cart_mandates"].find do |r|
          r["mandate_id"] == cart_mandate_id && r["user_id"] == user_id && r["raw_jws"] == cart_jws
        end
        return [] if cart.nil?
        return [] unless stored["intent_mandates"].any? do |r|
          r["id"] == cart["intent_mandate_id"] && r["user_id"] == user_id && r["raw_jws"] == intent_jws
        end
        return [] unless stored["payment_mandates"].any? do |r|
          r["cart_mandate_id"] == cart["id"] && r["user_id"] == user_id && r["raw_jws"] == payment_jws
        end

        stored["settlements"].select { |r| r["cart_mandate_id"] == cart["id"] }
      end

      before do
        stub_const("ActiveRecord::RecordNotUnique", Class.new(StandardError))

        %i[persist_intent_mandate persist_cart_mandate
           persist_payment_mandate persist_settlement].each do |helper|
          allow_any_instance_of(described_class).to receive(helper).and_call_original
        end

        route_exec_query(connection) do |sql, binds|
          if sql.include?("INSERT INTO")
            table = sql[/INSERT INTO \S+\.(\w+)/, 1]
            key   = [table, binds.first]
            raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint" \
              if inserted.include?(key)

            inserted << key
            id = "row-#{inserted.size}"
            stored[table] << insert_columns.fetch(table).zip(binds).to_h.merge("id" => id)
            [{ "id" => id }]
          elsif sql.include?("settlements s")
            settled_chain_rows(stored, binds)
          else
            [{ "id" => "row-#{inserted.size}" }]
          end
        end

        Kiosk.configuration.payment_provider = instance_double("PSP", setup_required?: false)
        allow(Kiosk.configuration.payment_provider).to receive(:capture) do |cart, **_kwargs|
          captures << cart.id
          settlement
        end
      end

      # THE ONE-CHARGE ASSERTION, and since K-850 also the IDEMPOTENCE one.
      # Same args, twice: the second call re-presents `intent-1`, the row is
      # already there, and the unique violation lands in phase 1 — BEFORE phase
      # 2 — where the executor asks whether THIS chain already settled. It did,
      # so the replay is answered with the settlement the first call returned.
      # The card is charged exactly once and no second settlement is minted.
      it "charges once and replays the ORIGINAL settlement the second time (K-850)" do
        first = described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        expect(first.payload).to include(settlement_id: "row-4")

        second = described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)

        expect(second.kind).to eq(:value)
        expect(second.payload).to eq(first.payload)
        expect(captures).to eq(["cart-1"])
        expect(inserted.count { |table, _| table == "settlements" }).to eq(1)
      end

      # A `409` on a replay would not have been idempotence — it would have been
      # a different answer to the same request, and one carrying none of the
      # settlement facts the assistant is missing. Pinned as its own example so
      # the regression reads as what it is.
      it "does not answer a settled replay with an error at all (K-850)" do
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)

        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.not_to raise_error
      end

      # THE BOUNDARY. A chain re-presented before anything settled — here the
      # trail is written and the capture then fails — has no settlement to hand
      # back, so it keeps `409 conflict`, raised before any capture. The 409 now
      # means one specific thing: "seen, and NOT settled".
      it "still answers 409 conflict when the re-presented chain never settled" do
        allow(Kiosk.configuration.payment_provider).to receive(:capture)
          .and_raise(Kiosk::PaymentProviders::PaymentFailed.new("declined", retryable: true))
        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.to raise_error(Kiosk::Server::Errors::PaymentFailed)

        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
          expect(e.http_status).to eq(409)
          expect(e.code).to        eq("conflict")
        }
        expect(inserted.count { |table, _| table == "settlements" }).to eq(0)
      end

      # AND THE OTHER HALF OF THE BOUNDARY: a settled cart `id` re-presented
      # with DIFFERENT signed bytes is not this request, so it is not handed
      # this request's settlement.
      it "refuses a settled cart id re-presented with different bytes (K-850)" do
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        tampered = Kiosk::Mandate::CartMandate.new(**cart.to_h, raw_jws: "cart-jws-TAMPERED")
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(tampered)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(payment)

        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
        expect(captures).to eq(["cart-1"])
      end

      # THE REACHABLE DOUBLE CHARGE, pinned so nobody has to take §11.6's word
      # for it. A client that answers a lost response by MINTING A FRESH CHAIN
      # collides with nothing: new `id`s, new rows, a second capture. Nothing in
      # the engine can tell this from a genuine second purchase — which is
      # exactly why the rule "retry the identical chain, never a fresh one"
      # lives in the spec and in skill.md rather than in the executor.
      it "charges TWICE when the retry mints a fresh chain (the case §11.6 forbids)" do
        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)

        remint = ->(mandate, id) { mandate.class.new(**mandate.to_h.merge(id: id)) }
        intent2 = remint.call(intent, "intent-2")
        cart2   = Kiosk::Mandate::CartMandate.new(**cart.to_h.merge(id: "cart-2", intent_mandate_id: "intent-2"))
        pay2    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h.merge(id: "pay-2", cart_mandate_id: "cart-2"))
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent).and_return(intent2)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(cart2)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(pay2)

        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)

        expect(captures).to eq(%w[cart-1 cart-2])
      end

      # ── K-851: the phase-3 window, walked end to end ────────────────────
      #
      # THE MEASURED REPRODUCTION. The capture SUCCEEDS and phase 3 — the
      # separate transaction that records it — fails. Everything after that is
      # the algorithm §11.6 prescribes, executed literally:
      #
      #   capture ok → persist_settlement raises → the request errors
      #   → assistant re-presents the IDENTICAL chain (§11.6's MUST)
      #   → phase 1 unique violation → 409 conflict
      #   → assistant reconciles: are there settlements for this cart? NO
      #   → the pre-K-851 §11.6 read that as "confirmed unpaid" and blessed a
      #     freshly signed chain → fresh cart id → fresh PSP idempotency key
      #   → SECOND REAL CHARGE for one purchase.
      #
      # This example is a CHARACTERIZATION of the engine, not a pin on the fix:
      # the engine still cannot record a capture it did not survive, and it
      # never could. What K-851 changed is what may be PUBLISHED about that
      # state — §11.6 now forbids an operator from answering `not paid` while a
      # capture may be outstanding and forbids an assistant from re-signing on
      # anything short of a positive `not paid`, which cuts the arrow between
      # step 4 and step 5 below. The engine behaviour asserted here is what
      # makes that rule necessary, so it is worth a test that says so out loud.
      it "leaves a charge with no settlement row when phase 3 fails, and the reconciling read cannot see it (K-851)" do
        allow_any_instance_of(described_class).to receive(:persist_settlement)
          .and_raise(StandardError, "connection reset during settlement insert")

        # 1. Capture succeeds; the settlement insert does not. The caller sees
        #    an error, and cannot tell it from "nothing happened".
        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.to raise_error(StandardError, /connection reset/)
        expect(captures).to eq(["cart-1"])
        expect(inserted.map(&:first)).to include("cart_mandates")
        expect(inserted.map(&:first)).not_to include("settlements")

        # 2. The assistant does what §11.6 REQUIRES: the identical chain again.
        expect {
          described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
        }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
          expect(e.http_status).to eq(409)
        }
        expect(captures).to eq(["cart-1"]) # the 409 is raised before any capture

        # 3. It reconciles. Every operator-side record of the money is the
        #    settlement row, and there is none — so a paid flag derived from
        #    settlements alone answers "not paid" about a charged cart. That
        #    false answer is the whole finding.
        expect(inserted.map(&:first)).not_to include("settlements")

        # 4. Acting on it — the freshly signed chain the old §11.6 called
        #    correct — charges the human a second time.
        allow_any_instance_of(described_class).to receive(:persist_settlement).and_call_original
        remint  = ->(mandate, id) { mandate.class.new(**mandate.to_h.merge(id: id)) }
        intent2 = remint.call(intent, "intent-2")
        cart2   = Kiosk::Mandate::CartMandate.new(**cart.to_h.merge(id: "cart-2", intent_mandate_id: "intent-2"))
        pay2    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h.merge(id: "pay-2", cart_mandate_id: "cart-2"))
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent).and_return(intent2)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(cart2)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(pay2)

        described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)

        expect(captures).to eq(%w[cart-1 cart-2])
      end
    end
  end

  # ── The pay path's statements carry BIND PARAMETERS, not spliced values ───
  #
  # K-654: these four INSERTs (and the spending-cap SELECT) used to be heredocs
  # with every field run through a private `q()` = `connection.quote`. This
  # group asserts the shape that replaced it — `$N` placeholders, values handed
  # over separately and in order — and, above all, that `connection.quote` is
  # not reachable from the pay path at all. A quoted value inside an assembled
  # string is safe exactly as long as nobody forgets one; there is now nothing
  # to forget, and that is the property worth a test.
  #
  # What this group deliberately does NOT claim is that the values are STORED
  # correctly: a fake connection cannot know what Postgres makes of a bind's
  # type. That is `executor_persistence_spec.rb`, against a real database.
  describe "pay-path persistence (bind parameters)" do
    subject(:executor) { described_class.new(connection: connection, identity: identity) }

    let(:expires_at) { Time.at(1_800_000_071) }
    let(:intent) do
      Kiosk::Mandate::IntentMandate.new(
        id: "intent-1", user_id: "u-1", agent_id: "a-1", issuer: "https://demo.example",
        scope: "groceries", cap_amount_cents: 5000, currency: "eur",
        expires_at: expires_at, created_at: expires_at, raw_jws: "intent-jws",
      )
    end
    let(:cart) do
      Kiosk::Mandate::CartMandate.new(
        id: "cart-1", intent_mandate_id: "intent-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://demo.example", line_items: [{ "sku" => "pizza", "qty" => 1 }],
        total_amount_cents: 1599, currency: "eur", expires_at: expires_at,
        created_at: expires_at, raw_jws: "cart-jws",
      )
    end
    let(:payment) do
      Kiosk::Mandate::PaymentMandate.new(
        id: "pay-1", cart_mandate_id: "cart-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://demo.example", payment_method: "pm_card_visa",
        amount_cents: 1599, currency: "eur", expires_at: expires_at,
        created_at: expires_at, raw_jws: "payment-jws",
      )
    end

    before { Kiosk.configure { |c| c.schema = "kiosk" } }

    # [sql, name, binds] of the single statement the call under test ran.
    def last_statement = connection.exec_queries.last

    it "binds every intent-mandate value and splices none of them into the SQL" do
      id = executor.send(:persist_intent_mandate, intent)
      sql, name, binds = last_statement

      expect(id).to   eq("row-1") # the RETURNING id the fake hands back
      expect(name).to eq("Kiosk intent_mandate insert")
      expect(sql).to  include("VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9)")
      expect(binds).to eq([
        "intent-1", "u-1", "a-1", "https://demo.example", "groceries",
        5000, "eur", expires_at, "intent-jws",
      ])
    end

    it "binds every cart-mandate value, with line_items as JSON text under an explicit ::jsonb cast" do
      executor.send(:persist_cart_mandate, cart, intent_row_id: "intent-row")
      sql, name, binds = last_statement

      expect(name).to eq("Kiosk cart_mandate insert")
      expect(sql).to  include("VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)")
      expect(binds).to eq([
        "cart-1", "intent-row", "u-1", "a-1", "https://demo.example",
        %([{"sku":"pizza","qty":1}]), 1599, "eur", expires_at, "cart-jws",
      ])
    end

    it "binds every payment-mandate value" do
      executor.send(:persist_payment_mandate, cart_row_id: "cart-row", payment: payment)
      sql, name, binds = last_statement

      expect(name).to eq("Kiosk payment_mandate insert")
      expect(sql).to  include("VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)")
      expect(binds).to eq([
        "pay-1", "cart-row", "u-1", "a-1", "https://demo.example",
        "pm_card_visa", 1599, "eur", expires_at, "payment-jws",
      ])
    end

    it "binds the 'on_file' sentinel rather than an empty payment_method" do
      on_file = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, payment_method: "")
      executor.send(:persist_payment_mandate, cart_row_id: "cart-row", payment: on_file)

      expect(last_statement[2][5]).to eq("on_file")
    end

    it "binds every settlement value" do
      executor.send(:persist_settlement, cart_row_id: "cart-row", cart: cart,
                                         settled: { psp_reference: "pi_1", settled_amount_cents: 1599 })
      sql, name, binds = last_statement

      expect(name).to eq("Kiosk settlement insert")
      expect(sql).to  include("VALUES ($1, $2, $3, $4, $5, $6, $7, now())")
      expect(binds).to eq(["cart-row", "u-1", "a-1", "https://demo.example", "pi_1", 1599, "eur"])
      # K-948: no `raw_jws` column, so no literal `''` trailing the VALUES list.
      # Asserted on the COLUMN list as well, because a statement that still
      # named the column while binding nothing would satisfy the line above.
      expect(sql).not_to include("raw_jws")
    end

    # The regression guard the row is actually about: no value — not even a
    # harmless one — may appear in the statement text, and `quote` must never
    # be called. Written over all four helpers so a future fifth statement
    # that forgets is caught by the same assertion.
    it "never calls connection.quote and never lets a value reach the SQL text" do
      expect(connection).not_to receive(:quote)

      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: payment)
      executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart,
                                         settled: { psp_reference: "pi_1", settled_amount_cents: 1599 })

      expect(connection.exec_queries.size).to eq(4)
      connection.exec_queries.each do |sql, _name, binds|
        binds.each do |value|
          next if value.is_a?(Integer) # a bare number is not evidence of splicing

          expect(sql).not_to include(value.to_s)
        end
      end
    end

    describe "#settled_total_cents" do
      before { connection.next_exec_result = [{ "total" => 0 }] }

      it "binds the agent and the currency, with no window predicate when uncapped by time" do
        executor.send(:settled_total_cents, agent_id: "a-1", window_days: nil, currency: "eur")
        sql, name, binds = last_statement

        expect(name).to eq("Kiosk settled total")
        # K-1251: the predicate folds the COLUMN, for settlement rows written
        # before the mandate boundary canonicalised what fills it.
        expect(sql).to  include("WHERE agent_id = $1 AND lower(btrim(currency)) = $2")
        expect(sql).not_to include("settled_at")
        expect(binds).to eq(["a-1", "eur"])
      end

      # The window used to be `#{window_days.to_i} * INTERVAL '1 day'` — the
      # last interpolation in the file, and the one the third-party review
      # missed. It is a bind now.
      it "binds the window length rather than interpolating the day count" do
        executor.send(:settled_total_cents, agent_id: "a-1", window_days: 7, currency: "eur")
        sql, _name, binds = last_statement

        expect(sql).to include("AND settled_at >= now() - make_interval(days => $3)")
        expect(sql).not_to include("7")
        expect(binds).to eq(["a-1", "eur", 7])
      end

      # K-1251: the BIND is folded too, so a caller that hands over a cart the
      # verifier never canonicalised still reads the same tally.
      it "canonicalises the currency it binds" do
        executor.send(:settled_total_cents, agent_id: "a-1", window_days: nil, currency: " EUR ")
        _sql, _name, binds = last_statement

        expect(binds).to eq(["a-1", "eur"])
      end
    end
  end
end
