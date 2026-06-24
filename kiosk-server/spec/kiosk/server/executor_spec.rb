# frozen_string_literal: true

RSpec.describe Kiosk::Server::Executor do
  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: "agent") }

  describe ".call construction" do
    it "raises Unauthenticated when identity is nil" do
      expect {
        described_class.call(kind: :sql, args: { sql: "SELECT 1" }, identity: nil, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /identity/)
    end

    it "raises BadRequest for an unknown verb" do
      expect {
        described_class.call(kind: :wat, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest) { |e|
        expect(e.hint).to include("sql")
      }
    end
  end

  describe "transaction discipline" do
    it "wraps the verb in a single transaction with GUCs set" do
      connection.next_result = [{ ok: 1 }]
      described_class.call(kind: :sql, args: { sql: "SELECT 1" }, identity: identity, connection: connection)

      # 4 SET LOCAL + 1 SELECT
      expect(connection.executed_sql.size).to eq(5)
      expect(connection.executed_sql[0]).to start_with(%(SET LOCAL "app"."current_user_id"))
      expect(connection.executed_sql[3]).to start_with(%(SET LOCAL "app"."current_agent_id"))
      expect(connection.executed_sql[4]).to eq("SELECT 1")
      expect(connection.in_transaction?).to be(false) # closed after call
    end
  end

  describe "verb :sql" do
    it "executes the SQL string and returns :rows Result" do
      connection.next_result = [{ id: 1, name: "a" }, { id: 2, name: "b" }]
      result = described_class.call(
        kind: :sql, args: { sql: "SELECT id, name FROM users" },
        identity: identity, connection: connection,
      )

      expect(result).to be_a(Kiosk::Server::Result)
      expect(result.kind).to    eq(:rows)
      expect(result.payload).to eq([{ id: 1, name: "a" }, { id: 2, name: "b" }])
    end

    it "accepts the sql arg as a bare String when args isn't a Hash" do
      result = described_class.call(
        kind: :sql, args: "SELECT 1",
        identity: identity, connection: connection,
      )
      expect(connection.executed_sql.last).to eq("SELECT 1")
      expect(result.kind).to eq(:rows)
    end

    it "raises BadRequest when args.sql is missing" do
      expect {
        described_class.call(kind: :sql, args: {}, identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /sql/)
    end
  end

  describe "verb :run" do
    before do
      Kiosk::Server::Actions.register("ping") { |args| { pong: args[:greeting] } }
    end

    it "looks up the action by name and calls it with sym-keyed args" do
      result = described_class.call(
        kind: :run, args: { name: "ping", greeting: "world" },
        identity: identity, connection: connection,
      )

      expect(result.kind).to    eq(:value)
      expect(result.payload).to eq(pong: "world")
    end

    it "passes through args (except name) to the action handler" do
      Kiosk::Server::Actions.register("echo") { |args| args }
      result = described_class.call(
        kind: :run, args: { name: "echo", a: 1, b: "x" },
        identity: identity, connection: connection,
      )
      expect(result.payload).to eq(a: 1, b: "x")
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
      Kiosk::Server::Actions.register("denied") { raise Kiosk::Server::Errors::RLSDenied, "no" }

      expect {
        described_class.call(kind: :run, args: { name: "denied" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::RLSDenied)
    end

    it "wraps StandardError raised inside the action as ActionFailed" do
      Kiosk::Server::Actions.register("boom") { raise "kaboom" }

      expect {
        described_class.call(kind: :run, args: { name: "boom" },
                             identity: identity, connection: connection)
      }.to raise_error(Kiosk::Server::Errors::ActionFailed, /kaboom/)
    end
  end

  describe "stub verbs (deferred to follow-up release)" do
    %i[schema help events].each do |verb|
      it ":#{verb} raises NotImplementedError with a descriptive message" do
        expect {
          described_class.call(kind: verb, args: {}, identity: identity, connection: connection)
        }.to raise_error(NotImplementedError, /follow-up|kiosk-pay/)
      end
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
    let(:settlement) { { psp_reference: "pi_1", settled_amount_cents: 1599, settled_at: Time.now } }
    let(:valid_args) { { intent_mandate_jws: "intent-jws", cart_mandate_jws: "cart-jws" } }

    before do
      Kiosk.reset!
      Kiosk.configure { |c| c.issuer = "https://demo.example" }
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent)
        .with(raw_jws: "intent-jws", identity: identity).and_return(intent)
      allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart)
        .with(raw_jws: "cart-jws", identity: identity, intent: intent).and_return(cart)
      allow_any_instance_of(described_class).to receive(:persist_intent_mandate)
      allow_any_instance_of(described_class).to receive(:persist_cart_mandate)
      allow_any_instance_of(described_class).to receive(:persist_payment_mandate).and_return("pm-1")
      Kiosk.configuration.payment_provider = instance_double("PSP", capture: settlement)
    end

    it "verifies the trail, captures, and returns the full settlement payload" do
      result = described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      expect(result.kind).to eq(:value)
      expect(result.payload).to include(
        payment_mandate_id:   "pm-1",
        psp_reference:        "pi_1",
        settled_amount_cents: 1599,
        currency:             "eur",
      )
    end

    # C2: an irreversible PSP capture must never run inside a DB transaction —
    # a ROLLBACK cannot undo a Stripe charge. FakeConnection tracks tx depth.
    it "captures OUTSIDE any DB transaction" do
      in_tx_at_capture = nil
      Kiosk.configuration.payment_provider = instance_double("PSP")
      allow(Kiosk.configuration.payment_provider).to receive(:capture) do |_cart|
        in_tx_at_capture = connection.in_transaction?
        settlement
      end

      described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection)
      expect(in_tx_at_capture).to be(false)
    end

    it "raises BadRequest when intent_mandate_jws is missing" do
      expect { described_class.call(kind: :pay, args: { cart_mandate_jws: "cart-jws" },
        identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /intent_mandate_jws/)
    end

    it "raises BadRequest when cart_mandate_jws is missing" do
      expect { described_class.call(kind: :pay, args: { intent_mandate_jws: "intent-jws" },
        identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /cart_mandate_jws/)
    end

    it "raises Forbidden when no payment_provider is configured" do
      Kiosk.configuration.payment_provider = nil
      expect { described_class.call(kind: :pay, args: valid_args, identity: identity, connection: connection) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /payment_provider/)
    end
  end
end
