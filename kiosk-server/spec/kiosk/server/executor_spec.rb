# frozen_string_literal: true

RSpec.describe Kiosk::Server::Executor do
  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: "agent") }

  describe ".call construction" do
    it "raises Unauthenticated when identity is nil" do
      expect {
        described_class.call(kind: :run, args: { name: "ping" }, identity: nil, connection: connection)
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
      described_class.call(kind: :query, args: { name: "probe" }, identity: identity, connection: connection)

      # 4 SET LOCAL GUCs only (the handler renders rows without hitting connection)
      expect(connection.executed_sql.size).to eq(4)
      expect(connection.executed_sql[0]).to start_with(%(SET LOCAL "app"."current_user_id"))
      expect(connection.executed_sql[3]).to start_with(%(SET LOCAL "app"."current_agent_id"))
      expect(connection.in_transaction?).to be(false) # closed after call
    end
  end

  describe "verb :query" do
    before do
      declare_query("menu") { render json: [{ "id" => 1, "name" => "Margherita" }] }
    end

    it "looks up the query by name and returns :rows Result" do
      result = described_class.call(
        kind: :query, args: { name: "menu" },
        identity: identity, connection: connection,
      )

      expect(result).to be_a(Kiosk::Server::Result)
      expect(result.kind).to    eq(:rows)
      expect(result.payload).to eq([{ "id" => 1, "name" => "Margherita" }])
    end

    it "passes params (args minus name) to the query handler" do
      declare_query("items") { render json: [{ filter: params[:category] }] }
      result = described_class.call(
        kind: :query, args: { name: "items", category: "pizza" },
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
        described_class.call(kind: :query, args: { name: "missing" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::NotFound)
    end

    it "lets Kiosk::Server::Errors raised inside the query propagate unchanged" do
      declare_query("denied") { raise Kiosk::Server::Errors::RLSDenied, "no" }

      expect {
        described_class.call(kind: :query, args: { name: "denied" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end

    it "wraps StandardError raised inside the query as ActionFailed" do
      declare_query("boom") { raise "kaboom" }

      expect {
        described_class.call(kind: :query, args: { name: "boom" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed, /kaboom/)
    end

    # ── cursor pagination seam (ADR-0021 / T-042) ─────────────────────────

    it "leaves next_cursor nil when the handler returns a bare Array (back-compat)" do
      declare_query("flat") { render json: [{ "id" => 1 }, { "id" => 2 }] }
      result = described_class.call(kind: :query, args: { name: "flat" },
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ "id" => 1 }, { "id" => 2 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_envelope).not_to have_key(:next)
    end

    it "threads a Page's next_cursor into the result envelope as `next`" do
      declare_query("paged") do
        offset = Kiosk::Server::Cursor.decode_offset(params[:cursor])
        render_kiosk_page([{ "id" => offset + 1 }],
                          next_cursor: Kiosk::Server::Cursor.encode_offset(offset + 1))
      end

      result = described_class.call(kind: :query, args: { name: "paged", limit: 1 },
                                    identity: identity, connection: connection)

      expect(result.kind).to        eq(:rows)
      expect(result.payload).to     eq([{ "id" => 1 }])
      expect(result.next_cursor).to eq(Kiosk::Server::Cursor.encode_offset(1))
      expect(result.to_envelope[:next]).to eq(result.next_cursor)
    end

    it "omits `next` when a paginating handler signals the last page (Page with nil cursor)" do
      declare_query("last") do
        render_kiosk_page([{ "id" => 99 }]) # no next_cursor => complete
      end
      result = described_class.call(kind: :query, args: { name: "last" },
                                    identity: identity, connection: connection)

      expect(result.payload).to     eq([{ "id" => 99 }])
      expect(result.next_cursor).to be_nil
      expect(result.to_envelope).not_to have_key(:next)
    end
  end

  describe "verb :run" do
    before do
      declare_action("ping") { render json: { pong: params[:greeting] } }
    end

    it "looks up the action by name and calls it with sym-keyed args" do
      result = described_class.call(
        kind: :run, args: { name: "ping", greeting: "world" },
        identity: identity, connection: connection,
      )

      expect(result.kind).to    eq(:value)
      # String keys: the handler renders, so the value makes a JSON round trip.
      expect(result.payload).to eq("pong" => "world")
    end

    it "passes through args (except name) to the action handler" do
      declare_action("echo") { render json: { a: params[:a], b: params[:b] } }
      result = described_class.call(
        kind: :run, args: { name: "echo", a: 1, b: "x" },
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
        described_class.call(kind: :run, args: { name: "missing" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::NotFound)
    end

    it "lets Kiosk::Server::Errors raised inside the action propagate unchanged" do
      declare_action("denied") { raise Kiosk::Server::Errors::RLSDenied, "no" }

      expect {
        described_class.call(kind: :run, args: { name: "denied" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end

    it "wraps StandardError raised inside the action as ActionFailed" do
      declare_action("boom") { raise "kaboom" }

      expect {
        described_class.call(kind: :run, args: { name: "boom" },
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

  describe "verb :schema" do
    before do
      declare_query("menu", description: "Browse the menu",
        input_schema: { type: "object", properties: { restaurant_id: { type: "string" } } })
      declare_action("place_order", description: "Place an order",
        input_schema: { type: "object", properties: { items: { type: "array" } } })
    end

    it "returns a :value Result with verbs, queries catalog, and actions catalog" do
      result = described_class.call(kind: :schema, args: {}, identity: identity, connection: connection)

      expect(result).to be_a(Kiosk::Server::Result)
      expect(result.kind).to eq(:value)
      expect(result.payload[:verbs]).to include("query", "run", "pay", "schema")
      expect(result.payload[:verbs]).not_to include("help", "events")
      # `params` is retired (ADR-0023): the shape lives in input_schema and the
      # descriptor publishes the retired slot as null.
      expect(result.payload[:queries]).to include(
        hash_including(name: "menu", description: "Browse the menu", params: nil,
                       input_schema: { type: "object", properties: { restaurant_id: { type: "string" } } }),
      )
      expect(result.payload[:actions]).to include(
        hash_including(name: "place_order", description: "Place an order", params: nil,
                       input_schema: { type: "object", properties: { items: { type: "array" } } }),
      )
    end

    it "does not open a SessionContext (zero DB calls)" do
      described_class.call(kind: :schema, args: {}, identity: identity, connection: connection)
      expect(connection.executed_sql).to be_empty
    end

    it "includes entries declared without a description (description/params nil)" do
      declare_query("bare", input_schema: { type: "object" })
      result = described_class.call(kind: :schema, args: {}, identity: identity, connection: connection)

      bare = result.payload[:queries].find { |q| q[:name] == "bare" }
      expect(bare).not_to be_nil
      expect(bare[:description]).to be_nil
      expect(bare[:params]).to be_nil
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
      expect(sql).to  include("VALUES ($1, $2, $3, $4, $5, $6, $7, now(), '')")
      expect(binds).to eq(["cart-row", "u-1", "a-1", "https://demo.example", "pi_1", 1599, "eur"])
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
        expect(sql).to  include("WHERE agent_id = $1 AND currency = $2")
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
    end
  end
end
