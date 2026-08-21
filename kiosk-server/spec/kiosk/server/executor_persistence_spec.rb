# frozen_string_literal: true

require "active_record"
require "securerandom"

# The four `persist_*` helpers — plus `settled_total_cents` — against a REAL
# Postgres.
#
# WHY THIS FILE EXISTS. Everywhere else the Executor is driven through
# `FakeConnection`, which records SQL as a string and asserts nothing about
# what a database would do with it; `executor_spec.rb` STUBS all four persist
# helpers outright, so until this file the only place kiosk-server writes to
# the database on the pay path had no coverage of what actually lands in the
# row. That was tolerable while every value was spliced into the SQL text
# through `connection.quote` — the text WAS the behaviour, and you could read
# it. It is not tolerable now that the values travel as BIND PARAMETERS
# (K-654): a bind carries its value out-of-band, so the one thing that can go
# wrong silently is the TYPE. A jsonb argument that arrives as a json *string*,
# a uuid that arrives as text, a `Time` that loses its zone — none of those
# change the SQL text by one byte, and none of them can be caught by a fake.
# Only a real Postgres can tell you.
#
# These specs were written and run GREEN against the interpolated
# implementation FIRST, then re-run against the bind-parameter one, so the
# conversion is provably behaviour-preserving rather than merely green.
#
# Connection from PG* env vars (CI's service) or the local default socket; no
# reachable server → skip, never fail, so DB-less machines stay green (the same
# contract as `device_authorization_stores_spec.rb` and `pow_spent_stores_spec.rb`).
RSpec.describe Kiosk::Server::Executor do
  describe "mandate persistence (real Postgres)" do
    # Deliberately NOT named SPEC_SCHEMA: `device_authorization_stores_spec.rb`
    # already defines a top-level constant by that name, and a second one would
    # silently overwrite it for whichever file loads later.
    PERSIST_SPEC_SCHEMA = "kiosk_executor_persist_spec"

    def self.postgres_error
      @postgres_error ||= begin
        ::ActiveRecord::Base.establish_connection(
          adapter:  "postgresql",
          host:     ENV["PGHOST"],
          username: ENV["PGUSER"],
          password: ENV["PGPASSWORD"],
          database: ENV.fetch("PGDATABASE", "postgres"),
        )
        ::ActiveRecord::Base.connection.execute("SELECT 1")
        [false]
      rescue StandardError => e
        ["#{e.class}: #{e.message}"]
      end
      @postgres_error.first
    end

    before(:context) do
      skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error

      conn = ::ActiveRecord::Base.connection
      conn.execute(%(DROP SCHEMA IF EXISTS "#{PERSIST_SPEC_SCHEMA}" CASCADE))
      conn.execute(%(CREATE SCHEMA "#{PERSIST_SPEC_SCHEMA}"))
      # The SHIPPED migration SQL, not a hand-written table: the point of the
      # type assertions below is that the executor agrees with the schema
      # operators actually install.
      conn.execute(
        Kiosk::Server::SchemaDefinitions.mandates_sql(
          schema: PERSIST_SPEC_SCHEMA, user_id_type: :uuid,
        ),
      )
    end

    after(:context) do
      unless self.class.postgres_error
        ::ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{PERSIST_SPEC_SCHEMA}" CASCADE))
      end
    end

    let(:connection) { ::ActiveRecord::Base.connection }
    let(:user_uuid)  { SecureRandom.uuid }
    let(:agent_uuid) { SecureRandom.uuid }
    let(:identity)   { build_identity(user_id: user_uuid, agent_id: agent_uuid) }
    let(:executor)   { described_class.new(connection: connection, identity: identity) }

    # A fixed, non-round instant pinned to an offset that is NOT UTC and not
    # whole-hour, on purpose: the value reaches Postgres as a zone-LESS
    # `YYYY-MM-DD HH:MM:SS` string that the session interprets in UTC, so any
    # coercion that forgets to convert first lands 5h30m away and the epoch
    # assertion fails. (`MandateVerifier` builds these with `Time.at`, whose
    # zone is the server's, so "already UTC" must never be assumed.)
    let(:expires_at) { Time.at(1_800_000_071).localtime("+05:30") }

    let(:intent) do
      Kiosk::Mandate::IntentMandate.new(
        id: "intent-#{SecureRandom.hex(6)}", user_id: user_uuid, agent_id: agent_uuid,
        issuer: "https://demo.example", scope: "groceries", cap_amount_cents: 5000,
        currency: "eur", expires_at: expires_at, created_at: expires_at, raw_jws: "intent-jws"
      )
    end

    let(:line_items) { [{ "sku" => "pizza", "qty" => 2 }, { "sku" => "cola", "qty" => 1 }] }

    let(:cart) do
      Kiosk::Mandate::CartMandate.new(
        id: "cart-#{SecureRandom.hex(6)}", intent_mandate_id: intent.id, user_id: user_uuid,
        agent_id: agent_uuid, issuer: "https://demo.example", line_items: line_items,
        total_amount_cents: 1599, currency: "eur", expires_at: expires_at,
        created_at: expires_at, raw_jws: "cart-jws"
      )
    end

    let(:payment) do
      Kiosk::Mandate::PaymentMandate.new(
        id: "pay-#{SecureRandom.hex(6)}", cart_mandate_id: cart.id, user_id: user_uuid,
        agent_id: agent_uuid, issuer: "https://demo.example", payment_method: "pm_card_visa",
        amount_cents: 1599, currency: "eur", expires_at: expires_at,
        created_at: expires_at, raw_jws: "payment-jws"
      )
    end

    let(:settled) { { psp_reference: "pi_#{SecureRandom.hex(4)}", settled_amount_cents: 1599 } }

    before do
      Kiosk.configure do |c|
        c.schema = PERSIST_SPEC_SCHEMA
        c.issuer = "https://demo.example"
      end
      # CASCADE reaches cart_mandates → payment_mandates → settlements.
      connection.execute(%(TRUNCATE #{table('intent_mandates')} CASCADE))
    end

    def table(name) = %("#{PERSIST_SPEC_SCHEMA}".#{name})

    # Bind-parameterised read helper, so the spec's own queries can never be
    # the thing that proves a type.
    def one(sql, binds = [])
      connection.exec_query(sql, "persist spec", binds).to_a.first
    end

    def value(sql, binds = [])
      one(sql, binds)&.values&.first
    end

    # Persist the whole trail; returns the three server ids.
    def persist_trail
      intent_row = executor.send(:persist_intent_mandate, intent)
      cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
      executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: payment)
      [intent_row, cart_row]
    end

    # The helpers are private — they are the Executor's own persistence, not a
    # public seam — so the spec reaches them the only way there is.
    describe "#persist_intent_mandate" do
      it "returns the SERVER-generated uuid PK and persists every signed field" do
        id  = executor.send(:persist_intent_mandate, intent)
        row = one("SELECT * FROM #{table('intent_mandates')} WHERE id = $1", [id])

        expect(id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        expect(row["mandate_id"]).to       eq(intent.id)
        expect(row["user_id"]).to          eq(user_uuid)
        expect(row["agent_id"]).to         eq(agent_uuid)
        expect(row["issuer"]).to           eq("https://demo.example")
        expect(row["scope"]).to            eq("groceries")
        expect(row["cap_amount_cents"]).to eq(5000)
        expect(row["currency"]).to         eq("eur")
        expect(row["raw_jws"]).to          eq("intent-jws")
      end

      it "stores expires_at as the EXACT instant (a zone-dropping coercion lands on another second)" do
        id = executor.send(:persist_intent_mandate, intent)
        epoch = value("SELECT extract(epoch FROM expires_at)::bigint FROM #{table('intent_mandates')} WHERE id = $1", [id])
        expect(epoch.to_i).to eq(expires_at.to_i)
      end

      # The uuid columns are the second half of the type story. Postgres'
      # `uuid` type CANONICALISES on input, so an UPPERCASE agent id comes back
      # lower-cased — which a text column, or a value that reached a text
      # column, would not do. And a bind carrying an explicit TEXT type would
      # not reach the row at all: Postgres rejects `uuid = text` outright.
      it "stores agent_id as a real uuid (canonicalised on input, matchable as ::uuid)" do
        shouted = Kiosk::Mandate::IntentMandate.new(**intent.to_h, agent_id: agent_uuid.upcase)
        id = executor.send(:persist_intent_mandate, shouted)

        expect(value("SELECT agent_id::text FROM #{table('intent_mandates')} WHERE id = $1", [id]))
          .to eq(agent_uuid)
        expect(value("SELECT count(*) FROM #{table('intent_mandates')} WHERE agent_id = $1::uuid", [agent_uuid]).to_i)
          .to eq(1)
      end

      it "rejects a non-uuid agent_id at the database rather than storing it as text" do
        bogus = Kiosk::Mandate::IntentMandate.new(**intent.to_h, agent_id: "not-a-uuid")
        expect { executor.send(:persist_intent_mandate, bogus) }
          .to raise_error(::ActiveRecord::StatementInvalid)
      end

      # The whole point of the row (K-654): values are DATA, never SQL. This
      # passes under `connection.quote` too — that is what makes it the
      # regression guard rather than the proof of the conversion.
      it "round-trips a SQL-injection payload verbatim and leaves the table standing" do
        payload = "'); DROP TABLE #{table('intent_mandates')}; --"
        hostile = Kiosk::Mandate::IntentMandate.new(**intent.to_h, scope: payload, raw_jws: payload)
        id = executor.send(:persist_intent_mandate, hostile)
        row = one("SELECT scope, raw_jws FROM #{table('intent_mandates')} WHERE id = $1", [id])

        expect(row["scope"]).to   eq(payload)
        expect(row["raw_jws"]).to eq(payload)
        expect(value("SELECT count(*) FROM #{table('intent_mandates')}").to_i).to eq(1)
      end

      it "raises the unique violation the Executor maps to 409 when the same mandate id is replayed" do
        executor.send(:persist_intent_mandate, intent)
        expect { executor.send(:persist_intent_mandate, intent) }
          .to raise_error(::ActiveRecord::RecordNotUnique)
      end
    end

    describe "#persist_cart_mandate" do
      it "persists the cart against the SERVER intent id and returns its own server id" do
        intent_row = executor.send(:persist_intent_mandate, intent)
        cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
        row = one("SELECT * FROM #{table('cart_mandates')} WHERE id = $1", [cart_row])

        expect(row["intent_mandate_id"]).to  eq(intent_row)
        expect(row["mandate_id"]).to         eq(cart.id)
        expect(row["total_amount_cents"]).to eq(1599)
        expect(row["currency"]).to           eq("eur")
      end

      # ── THE TYPE ASSERTION THIS FILE EXISTS FOR ──────────────────────────
      #
      # `line_items` is `jsonb NOT NULL`, and the value handed to the insert is
      # JSON *text* (`cart.line_items.to_json`). It must land as a jsonb ARRAY.
      # A bind that coerced the argument to a json STRING — one extra
      # `to_json`, or a String-typed bind attribute against a `to_jsonb()`
      # style cast — stores the scalar `"[{\"sku\":\"pizza\"…}]"` instead:
      # `jsonb_typeof` answers "string", every `->`/`->>` answers NULL, and
      # every `line_items @> '[…]'::jsonb` containment answers FALSE. That last
      # one is the shape the demos' replace-guard (K-544) and the K-545
      # pay-race fix are written against, so it is asserted here directly even
      # though no containment predicate lives in kiosk-server itself.
      it "stores line_items as a jsonb ARRAY that satisfies @> containment (NOT a json string)" do
        _intent_row, cart_row = persist_trail

        expect(value("SELECT jsonb_typeof(line_items) FROM #{table('cart_mandates')} WHERE id = $1", [cart_row]))
          .to eq("array")
        expect(value("SELECT line_items -> 0 ->> 'sku' FROM #{table('cart_mandates')} WHERE id = $1", [cart_row]))
          .to eq("pizza")
        expect(value(
          "SELECT count(*) FROM #{table('cart_mandates')} WHERE id = $1 AND line_items @> $2::jsonb",
          [cart_row, [{ "sku" => "pizza", "qty" => 2 }].to_json],
        ).to_i).to eq(1)
        expect(value(
          "SELECT count(*) FROM #{table('cart_mandates')} WHERE id = $1 AND line_items @> $2::jsonb",
          [cart_row, [{ "sku" => "caviar" }].to_json],
        ).to_i).to eq(0)
      end

      it "refuses a cart whose intent_mandate_id is not a live intent row (FK, not a pre-check)" do
        expect { executor.send(:persist_cart_mandate, cart, intent_row_id: SecureRandom.uuid) }
          .to raise_error(::ActiveRecord::InvalidForeignKey)
      end
    end

    describe "#persist_payment_mandate" do
      it "persists the signed payment mandate against the SERVER cart id" do
        _intent_row, cart_row = persist_trail
        row = one("SELECT * FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row])

        expect(row["mandate_id"]).to     eq(payment.id)
        expect(row["payment_method"]).to eq("pm_card_visa")
        expect(row["amount_cents"]).to   eq(1599)
        expect(row["raw_jws"]).to        eq("payment-jws")
      end

      it "persists the 'on_file' sentinel when the mandate presents no payment_method" do
        intent_row = executor.send(:persist_intent_mandate, intent)
        cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
        on_file    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, payment_method: "")
        executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: on_file)

        expect(value("SELECT payment_method FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row]))
          .to eq("on_file")
      end

      it "persists a NULL expires_at when the mandate carries none (the column is nullable here)" do
        intent_row = executor.send(:persist_intent_mandate, intent)
        cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
        undated    = Kiosk::Mandate::PaymentMandate.new(**payment.to_h, expires_at: nil)
        executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: undated)

        expect(value("SELECT expires_at FROM #{table('payment_mandates')} WHERE cart_mandate_id = $1", [cart_row]))
          .to be_nil
      end
    end

    describe "#persist_settlement" do
      it "records the receipt against the SERVER cart id and returns its server id" do
        _intent_row, cart_row = persist_trail
        settlement_id = executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
        row = one("SELECT * FROM #{table('settlements')} WHERE id = $1", [settlement_id])

        expect(row["cart_mandate_id"]).to      eq(cart_row)
        expect(row["user_id"]).to              eq(user_uuid)
        expect(row["agent_id"]).to             eq(agent_uuid)
        expect(row["psp_reference"]).to        eq(settled[:psp_reference])
        expect(row["settled_amount_cents"]).to eq(1599)
        expect(row["currency"]).to             eq("eur")
        # Server-minted receipt: no agent JWS to carry.
        expect(row["raw_jws"]).to eq("")
        expect(row["settled_at"]).not_to be_nil
      end

      it "enforces one settlement per cart (UNIQUE (cart_mandate_id))" do
        _intent_row, cart_row = persist_trail
        executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
        expect { executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled) }
          .to raise_error(::ActiveRecord::RecordNotUnique)
      end
    end

    describe "#settled_total_cents" do
      before do
        _intent_row, cart_row = persist_trail
        executor.send(:persist_settlement, cart_row_id: cart_row, cart: cart, settled: settled)
      end

      it "sums this agent's settlements in the given currency" do
        expect(executor.send(:settled_total_cents, agent_id: agent_uuid, window_days: nil, currency: "eur"))
          .to eq(1599)
      end

      it "is currency-scoped (K-551): a different currency tallies zero" do
        expect(executor.send(:settled_total_cents, agent_id: agent_uuid, window_days: nil, currency: "usd"))
          .to eq(0)
      end

      it "is agent-scoped: another assistant's spend is not counted" do
        expect(executor.send(:settled_total_cents, agent_id: SecureRandom.uuid, window_days: nil, currency: "eur"))
          .to eq(0)
      end

      it "counts a settlement inside the rolling window" do
        expect(executor.send(:settled_total_cents, agent_id: agent_uuid, window_days: 7, currency: "eur"))
          .to eq(1599)
      end

      it "excludes a settlement older than the rolling window" do
        connection.exec_query(
          "UPDATE #{table('settlements')} SET settled_at = now() - INTERVAL '9 days'", "persist spec",
        )
        expect(executor.send(:settled_total_cents, agent_id: agent_uuid, window_days: 7, currency: "eur"))
          .to eq(0)
      end
    end

    # ── The settled replay (K-850), driven end to end ──────────────────────
    #
    # WHY IT IS HERE and not only in executor_spec.rb. The whole behaviour is a
    # LOOKUP: one statement that joins settlements to the three mandate tables
    # and compares the stored `raw_jws` of each against the bytes presented
    # now. A FakeConnection cannot tell you whether that join resolves, whether
    # the FK columns line up, or whether a uuid bind matches — only a real
    # Postgres can, which is this file's entire reason to exist. The unique
    # violation that reaches the rescue here is a REAL one, raised by the real
    # `UNIQUE (user_id, mandate_id)` in the shipped migration SQL.
    #
    # THE DECISION (Phil, 2026-08-21, ADR-0026): a `pay` replaying an
    # already-SETTLED cart is IDEMPOTENT — it returns the settlement the first
    # call returned. A re-presented chain that was never captured, or whose
    # capture is still in flight, keeps `409 conflict` before any capture.
    describe "a replayed pay (K-850)" do
      let(:captures) { [] }
      let(:provider) do
        psp = instance_double("PSP")
        allow(psp).to receive(:setup_required?).and_return(false)
        allow(psp).to receive(:capture) do |charged, **_kwargs|
          captures << charged.id
          { psp_reference: "pi_capture_#{captures.size}", settled_amount_cents: charged.total_amount_cents }
        end
        psp
      end

      let(:args) do
        { intent_mandate_jws:  intent.raw_jws,
          cart_mandate_jws:    cart.raw_jws,
          payment_mandate_jws: payment.raw_jws }
      end

      before do
        Kiosk.configuration.payment_provider = provider
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_intent).and_return(intent)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(cart)
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_payment).and_return(payment)
      end

      def pay
        described_class.call(kind: :pay, args: args, identity: identity, connection: connection)
      end

      def settlement_count
        value("SELECT count(*) FROM #{table('settlements')}").to_i
      end

      # THE PIN THE DECISION ASKED FOR: one capture, one settlement row, and
      # the SECOND call returns the FIRST call's answer field for field.
      it "answers the identical chain with the ORIGINAL settlement, and captures exactly once" do
        first = pay
        second = pay

        expect(second.kind).to eq(:value)
        expect(second.payload).to eq(first.payload)
        expect(second.payload[:psp_reference]).to eq("pi_capture_1")
        expect(captures).to eq([cart.id])   # NOT charged a second time
        expect(settlement_count).to eq(1)   # NO second settlement minted
      end

      # The replay is answered from the STORED row, so the settlement id it
      # hands back is the one the settlements table holds — not a fresh one.
      it "returns the stored settlement row, not a reconstruction" do
        first = pay
        stored = one("SELECT * FROM #{table('settlements')}")

        expect(first.payload[:settlement_id]).to eq(stored["id"])
        expect(pay.payload[:settlement_id]).to  eq(stored["id"])
      end

      # THE BOUNDARY THAT DOES NOT MOVE. The trail is persisted and NOTHING was
      # captured (the phase-1 rows of a call that died before, or during, the
      # capture). There is no settlement to hand back, and re-running the
      # capture on a re-presented chain is exactly the double charge §11.6
      # exists to prevent — so this stays `409`, raised before any capture.
      it "still answers 409 conflict for a re-presented chain that was never captured" do
        intent_row = executor.send(:persist_intent_mandate, intent)
        cart_row   = executor.send(:persist_cart_mandate, cart, intent_row_id: intent_row)
        executor.send(:persist_payment_mandate, cart_row_id: cart_row, payment: payment)

        expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/) { |e|
          expect(e.http_status).to eq(409)
          expect(e.code).to eq("conflict")
        }
        expect(captures).to be_empty
        expect(settlement_count).to eq(0)
      end

      # Same idea one phase later: the capture RETURNED but phase 3 never
      # committed. That is K-851's window, and the answer there is unchanged —
      # the engine has no settlement, so it must not pretend it has one.
      it "still answers 409 conflict when the capture happened but phase 3 never landed" do
        allow_any_instance_of(described_class).to receive(:persist_settlement)
          .and_raise(StandardError, "connection reset during settlement insert")
        expect { pay }.to raise_error(StandardError, /connection reset/)
        expect(captures).to eq([cart.id])
        expect(settlement_count).to eq(0)

        allow_any_instance_of(described_class).to receive(:persist_settlement).and_call_original
        expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict)
        expect(captures).to eq([cart.id])
      end

      # A MANDATE ID RE-USED WITH DIFFERENT CONTENT IS NOT A REPLAY. The cart
      # `id` is the settled one, the signed bytes are not — so the settlement
      # this principal already has must NOT be handed to it as the answer to a
      # different request. The `raw_jws` equality in the lookup is what says so.
      it "refuses to hand the settlement to a chain whose bytes differ (same id, new content)" do
        pay
        forged = Kiosk::Mandate::CartMandate.new(**cart.to_h, raw_jws: "cart-jws-TAMPERED")
        allow(Kiosk::Server::MandateVerifier).to receive(:verify_cart).and_return(forged)

        expect { pay }.to raise_error(Kiosk::Server::Errors::Conflict, /already processed/)
        expect(captures).to eq([cart.id])
        expect(settlement_count).to eq(1)
      end

      # And the lookup is scoped to the acting principal on every mandate row:
      # another assistant's user_id sees no settlement of this one's.
      it "does not answer a DIFFERENT principal with this principal's settlement" do
        pay
        stranger = build_identity(user_id: SecureRandom.uuid, agent_id: SecureRandom.uuid)
        expect(
          described_class.new(connection: connection, identity: stranger)
                         .send(:settlement_for_chain, intent: intent, cart: cart, payment: payment),
        ).to be_nil
      end
    end
  end
end
