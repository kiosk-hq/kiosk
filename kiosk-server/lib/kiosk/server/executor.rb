# frozen_string_literal: true

require "kiosk/server/action_log"
require "kiosk/server/errors"
require "kiosk/server/response_validation"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"
require "kiosk/server/queries"

module Kiosk
  module Server
    # Central dispatcher. Receives a verb (one of {VERBS}) + args +
    # {Kiosk::Identity} + a database connection. Opens {SessionContext}
    # (transaction + four transaction-local GUCs), routes to the
    # appropriate verb method, returns {Result} on success or raises
    # {Errors::Base} subclass on failure.
    #
    # This implements the dispatch that {WireController} and
    # {VerbController} wrap, factored out of the controller so it is testable
    # without Rails.
    class Executor
      # The three GATE/POLICY verbs — the coarse kind of a call, NOT wire
      # paths — and what THIS dispatcher serves. ONE list, because since K-804
      # the two sets are the same one.
      #
      # Since the 0.4 cutover none of these three is a URL: `query` and `run`
      # are how a per-verb GET and a per-verb POST are classified for the toll
      # and the session, and `pay` is both a classification and a reserved path
      # segment. They stay symbols rather than becoming path names because
      # `reputation_factors` and `Policy#challenge_for` both take one as
      # `verb:` and every shipped policy branches on these three.
      #
      # THERE USED TO BE A SECOND CONSTANT, `POLICY_VERBS`, which was this list
      # plus `:schema`. `schema` left the DISPATCHER when T-094 made
      # `GET <endpoint>/schema` public — it resolves no identity, and an
      # {Executor} cannot be built without one — and stayed a POLICY verb for
      # exactly one caller: `/kiosk/openapi.json`, still gated, tolled as
      # `:schema` so a second spelling of the catalog could not be read around
      # the price. K-804 made that endpoint public too, so nothing tolls as
      # `:schema` and the second constant had become a byte-identical copy of
      # this one under another name — the same one-value-two-names shape K-801
      # retired from the wire. Deleted rather than left as documentation.
      #
      # `events` was removed long before: it was never a capability, the
      # Kiosk::Event type is gone, and the stub only ever raised a raw
      # NotImplementedError. An unknown kind is a clean 400.
      VERBS = %i[query run pay].freeze

      # Verbs that open their own transaction boundaries because they perform
      # an irreversible external side effect (a PSP capture) that a DB
      # ROLLBACK cannot undo. Everything else runs inside one wrapping
      # SessionContext; these manage their own SessionContext(s) instead.
      SELF_MANAGED_VERBS = %i[pay].freeze

      # @param name [String, nil] the query/action wire name. Always supplied
      #   on the wire — it is a PATH SEGMENT, not a body field — which is why a
      #   verb is free to declare an argument literally called `name` (none
      #   does; 0.3's wire could never have allowed one). Only `pay` ignores
      #   it: its name is its kind.
      def self.call(kind:, args:, identity:, connection:, name: nil)
        new(connection: connection, identity: identity).call(kind: kind, args: args, name: name)
      end

      attr_reader :connection, :identity

      def initialize(connection:, identity:)
        raise Errors::Unauthenticated, "identity required" if identity.nil?

        @connection = connection
        @identity   = identity
      end

      def call(kind:, args:, name: nil)
        verb = kind.to_sym
        unless VERBS.include?(verb)
          raise Errors::BadRequest.new(
            "Unknown verb: #{kind.inspect}",
            hint: "Valid verbs: #{VERBS.inspect}",
          )
        end

        if SELF_MANAGED_VERBS.include?(verb)
          dispatch(verb, args, name) # the verb manages its own SessionContext(s)
        elsif verb == :run
          audited(name, args) do
            SessionContext.open(connection: connection, identity: identity) do
              dispatch(verb, args, name)
            end
          end
        else
          SessionContext.open(connection: connection, identity: identity) do
            dispatch(verb, args, name)
          end
        end
      end

      private

      # THE AUDIT SEAM (T-088). Wraps the `run` branch above and writes one
      # {ActionLog} row per invocation — `ok` when the handler returned, `error`
      # when anything raised, and the raise is re-raised untouched either way.
      #
      # WHY HERE AND NOWHERE ELSE. This is the one place that sees every action
      # invocation exactly once. `POST <endpoint>/<action-name>` is the only
      # route to an action since the 0.4 cutover, and it reaches
      # {WireController#execute_wire} → `Executor.call(kind: :run)`; a direct
      # `Executor.call` (an RLS journey, an operator's own script) arrives at
      # the same line. Putting it in {#verb_run} instead would put it INSIDE
      # the SessionContext, where a failure's rollback would take the row with
      # it; putting it in the controller would miss the direct callers and
      # would sit inside the toll, where nothing has been invoked yet.
      #
      # OUTSIDE the SessionContext block, so the row survives a failed action's
      # ROLLBACK and is written with no GUCs and no `SET LOCAL ROLE` — see
      # {ActionLog} for why the log sits outside the RLS boundary.
      def audited(name, args)
        invoked_at = Time.now
        result     = yield
        log(name, args, ActionLog::OK, nil, invoked_at)
        result
      rescue StandardError => e
        log(name, args, ActionLog::ERROR, e, invoked_at)
        raise
      end

      def log(name, args, status, error, invoked_at)
        return unless ActionLog.loggable?(name)

        ActionLog.record(connection: connection, identity: identity, name: name.to_s,
                         args: args, status: status, error: error, invoked_at: invoked_at)
      end

      def dispatch(verb, args, name = nil)
        case verb
        when :query  then verb_query(args, name)
        when :run    then verb_run(args, name)
        when :pay    then verb_pay(args)
        end
      end

      # ─── query ─────────────────────────────────────────────────────────

      # A query handler returns either a bare Array of rows (the unchanged,
      # unpaginated case) or a {Page} (rows + an opaque next_cursor, and
      # optionally the matching-row total) to opt into cursor pagination. The
      # handler reads the optional `limit`/`cursor` args itself; the Executor
      # only threads the two page facts onto the {Result}, from which the wire
      # writes them as the `Link` and `X-Total-Count` response headers. The
      # BODY is the rows either way (spec §8.2).
      # Any other return value (e.g. a Hash from an idiosyncratic query) is
      # passed through as the rows payload unchanged, preserving back-compat.
      def verb_query(args, name = nil)
        args = symbolize(args)
        raise Errors::BadRequest, "query name required" if name.nil? || name.to_s.empty?

        handler = Queries.fetch(name)
        begin
          returned = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          raise Errors::ActionFailed.new("Query #{name.inspect} raised #{e.class}: #{e.message}",
                                         hint: "See server logs for the backtrace.")
        end

        result = if returned.is_a?(Page)
                   Result.new(kind:        :rows,
                              payload:     returned.rows,
                              next_cursor: returned.next_cursor,
                              total:       returned.total)
                 else
                   Result.new(kind: :rows, payload: returned)
                 end
        validate_response!(Queries, :query, name, result)
      end

      # ─── run ───────────────────────────────────────────────────────────

      def verb_run(args, name = nil)
        args = symbolize(args)
        raise Errors::BadRequest, "action name required" if name.nil? || name.to_s.empty?

        handler = Actions.fetch(name)
        begin
          value = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          raise Errors::ActionFailed.new(
            "Action #{name.inspect} raised #{e.class}: #{e.message}",
            hint: "See server logs for the backtrace.",
          )
        end

        validate_response!(Actions, :action, name, Result.new(kind: :value, payload: value))
      end

      # ─── the declared output shape (T-073 = A) ─────────────────────────

      # Checks the answer against the `output_schema` the verb published, when
      # the operator asked for it (`Kiosk.configuration.validate_responses`;
      # default off — see {ResponseValidation} for why it is a
      # development/CI assertion rather than a request check).
      #
      # It validates {Result#to_payload} — the answer shape — so the check is
      # exactly the body the caller receives. Returns the Result so it can wrap
      # the return value.
      def validate_response!(registry, kind, name, result)
        return result unless Kiosk.configuration.validate_responses

        ResponseValidation.validate_payload!(
          result.to_payload,
          output_schema: registry.describe(name)[:output_schema],
          verb:          name.to_s,
          kind:          kind,
        )
        result
      end

      # ─── pay ───────────────────────────────────────────────────────────

      # Settles an AP2 cart. `pay` is a SELF_MANAGED_VERB: it owns its
      # transaction boundaries because the PSP capture in phase 2 is an
      # irreversible external effect a DB ROLLBACK cannot undo, so it MUST
      # NOT run inside a wrapping transaction.
      #
      # The agent presents the whole trail (intent → cart); we verify and
      # persist both before charging, so the cart row's intent FK resolves.
      #
      # Three phases, capture strictly between two DB transactions:
      #   P1  verify + persist the mandate trail (GUC-scoped transaction — no
      #       RLS policy on the mandate tables yet). No external effect yet.
      #                            FAIL ⇒ nothing charged, rows rolled back.
      #   P2  irreversible PSP capture, OUTSIDE any DB transaction, keyed for
      #       idempotency by cart.id. A charge FAILURE (decline / auth-required /
      #       timeout) is translated by the adapter into a PSP-agnostic
      #       PaymentFailed and surfaced here as a typed `payment_failed` (402),
      #       NOT a raw 500 (K-545). A DEFINITIVE decline moved no money and is
      #       safe to retry; an UNKNOWN outcome (timeout) must be reconciled via
      #       my_orders before any retry, so a lost-response retry can't
      #       double-charge.
      #   P3  record the settlement (fresh GUC-scoped transaction).
      #       FAIL ⇒ charge + trail exist, payment row missing. The cart row +
      #              Stripe's cart.id-scoped idempotency key make the charge
      #              recoverable, but NO reconciliation worker exists yet —
      #              follow-up. Never a silent double-charge.
      def verb_pay(args)
        args         = symbolize(args)
        raw_intent   = args[:intent_mandate_jws]
        raw_cart     = args[:cart_mandate_jws]
        raw_payment  = args[:payment_mandate_jws]
        raise Errors::BadRequest, "args.intent_mandate_jws required"   if raw_intent.nil?  || raw_intent.to_s.empty?
        raise Errors::BadRequest, "args.cart_mandate_jws required"     if raw_cart.nil?    || raw_cart.to_s.empty?
        raise Errors::BadRequest, "args.payment_mandate_jws required"  if raw_payment.nil? || raw_payment.to_s.empty?

        # Payment is agent-only: the AP2 mandate chain is signed by the agent's
        # payment key. A non-agent principal (e.g. a web/mobile user_idp session,
        # agent_id nil) has no payment key, so reject it cleanly
        # here rather than letting agent_payment_key(nil) raise InvalidToken →
        # HTTP 500 downstream (same 500-not-4xx class as the other guarded paths).
        if identity.agent_id.nil?
          raise Errors::Forbidden, "payment requires an agent identity (mandates are agent-signed)"
        end

        provider = Kiosk.configuration.payment_provider
        raise Errors::Forbidden, "no payment_provider configured" if provider.nil?

        # Pre-check: if the provider knows the principal has no saved payment
        # method, return a clean 402 NOW — before Phase 1 persists anything.
        # This prevents burning the mandate ids on a charge that cannot
        # succeed, so the agent can retry after the human completes the
        # SetupIntent flow without hitting the UNIQUE (user_id, mandate_id)
        # idempotency key.
        if provider.respond_to?(:setup_required?) && provider.setup_required?(user_id: identity.user_id)
          raise Errors::PaymentSetupRequired
        end

        # Phase 1 — verify + persist the full mandate trail (GUC-scoped
        # transaction; no RLS policy on the mandate tables yet). The persist
        # helpers return the SERVER-generated uuid PKs, which thread the FK
        # chain. A unique violation (same signed mandate replayed) rolls the tx
        # back and propagates here, where it becomes a clean 409 Conflict.
        cart    = nil
        cart_row = nil
        payment = nil
        begin
          SessionContext.open(connection: connection, identity: identity) do
            intent  = MandateVerifier.verify_intent(raw_jws: raw_intent, identity: identity)
            cart    = MandateVerifier.verify_cart(raw_jws: raw_cart, identity: identity, intent: intent)
            # Per-assistant spending cap. Checked here — after the cart
            # is known, before any mandate row is persisted and before the
            # irreversible capture — so a rejection rolls back cleanly (nothing
            # persisted, no charge, no burned mandate id).
            enforce_spending_cap!(cart)
            payment = MandateVerifier.verify_payment(raw_jws: raw_payment, identity: identity, cart: cart)
            intent_row = persist_intent_mandate(intent)
            cart_row   = persist_cart_mandate(cart, intent_row_id: intent_row)
            persist_payment_mandate(cart_row_id: cart_row, payment: payment)
          end
        rescue StandardError => e
          raise Errors::Conflict.new("mandate already processed") if unique_violation?(e)

          raise
        end

        # Phase 2 — irreversible external capture. OUTSIDE any DB transaction.
        # The assistant-presented payment_method is threaded from the verified
        # PaymentMandate so the PSP charges THAT instrument (nil in the
        # SetupIntent model — the adapter resolves the on-file card itself).
        #
        # Belt-and-suspenders: if the PSP raises SetupRequired at capture time
        # (e.g. the on-file card was detached between the pre-check and now),
        # surface a clean 402 rather than a 500.
        #
        # K-545: a normal charge FAILURE (card declined, authentication
        # required, insufficient funds, or a processor timeout) must not escape
        # as a raw 500 with the mandate trail already burned. The adapter
        # translates its PSP-specific error into a PSP-agnostic PaymentFailed
        # carrying a human-safe message (no raw PSP internals); map it to the
        # typed `payment_failed` wire error (402). The hint depends on whether
        # the outcome was DEFINITIVE (safe to retry) or UNKNOWN (check
        # my_orders first so a lost-response retry can't double-charge).
        settled = begin
          provider.capture(cart, payment_method: payment.payment_method)
        rescue Kiosk::PaymentProviders::SetupRequired
          raise Errors::PaymentSetupRequired
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          hint = if e.retryable?
                   "the charge did not go through; no money moved. The human may need to " \
                     "update the payment method (payment_setup), then retry pay."
                 else
                   "the charge status is UNKNOWN (the processor did not confirm). Do NOT blindly " \
                     "retry — first check `query my_orders` for this order's paid flag; retry only " \
                     "if it is still unpaid."
                 end
          raise Errors::PaymentFailed.new(e.message, hint: hint)
        end

        # Phase 3 — record settlement (fresh GUC-scoped transaction; no RLS
        # policy on the mandate tables yet).
        settlement_id = nil
        SessionContext.open(connection: connection, identity: identity) do
          settlement_id = persist_settlement(cart_row_id: cart_row, cart: cart, settled: settled)
        end

        Result.new(kind: :value, payload: {
          settlement_id:        settlement_id,
          psp_reference:        settled[:psp_reference],
          settled_amount_cents: settled[:settled_amount_cents],
          currency:             cart.currency,
        })
      end

      # Inserts the intent-mandate row under the open SessionContext
      # (GUC-scoped transaction; no RLS policy on the mandate tables yet). The
      # PK is SERVER-generated (`gen_random_uuid()` DEFAULT) — never the
      # agent-supplied id, which lands in `mandate_id` for audit + per-principal
      # idempotency. Persists the verified `expires_at`. Returns the server id
      # the cart row references by FK.
      def persist_intent_mandate(intent)
        schema = Kiosk.configuration.schema
        sql = <<~SQL
          INSERT INTO #{schema}.intent_mandates
            (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
             currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9)
          RETURNING id
        SQL
        insert_returning_id("Kiosk intent_mandate insert", sql, [
          intent.id, intent.user_id, intent.agent_id, intent.issuer, intent.scope,
          intent.cap_amount_cents.to_i, intent.currency, intent.expires_at, intent.raw_jws,
        ])
      end

      # Inserts the cart-mandate row under the open SessionContext (GUC-scoped
      # transaction; no RLS policy on the mandate tables yet). The PK is
      # SERVER-generated; the agent-signed id lands in `mandate_id`.
      # `intent_mandate_id` references the SERVER intent id returned by phase 1
      # (`intent_row_id`), NOT the signed `cart.intent_mandate_id` — the DB FK
      # uses server ids; the cryptographic intent↔cart binding is checked
      # separately in MandateVerifier#verify_cart. Persists the verified
      # `expires_at`. Returns the server id the payment row references by FK.
      def persist_cart_mandate(cart, intent_row_id:)
        schema = Kiosk.configuration.schema
        # `$6::jsonb` is the ONE hand-written cast in these four statements.
        # Every other placeholder takes its type from the INSERT's target
        # column, but `line_items` arrives as JSON *text* and the cast is what
        # says "parse this, do not store it as a json string" — the difference
        # between a jsonb array a `@> '[…]'::jsonb` containment can match and a
        # scalar string it never will.
        sql = <<~SQL
          INSERT INTO #{schema}.cart_mandates
            (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
             total_amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)
          RETURNING id
        SQL
        insert_returning_id("Kiosk cart_mandate insert", sql, [
          cart.id, intent_row_id, cart.user_id, cart.agent_id, cart.issuer,
          cart.line_items.to_json, cart.total_amount_cents.to_i, cart.currency,
          cart.expires_at, cart.raw_jws,
        ])
      end

      # Inserts the signed payment-mandate row under the open SessionContext
      # (GUC-scoped transaction; no RLS policy on the mandate tables yet). The
      # PK is SERVER-generated; `cart_mandate_id` references the SERVER cart id
      # returned by phase 1 (`cart_row_id`), threading the FK chain. The
      # agent-signed id lands in `mandate_id`; `raw_jws` carries the full signed
      # token for audit. `UNIQUE (user_id, mandate_id)` prevents replay.
      def persist_payment_mandate(cart_row_id:, payment:)
        schema = Kiosk.configuration.schema
        # payment_method is optional in the SetupIntent model (the principal's
        # on-file card is the funding source, not a presented PM). Persist
        # "on_file" as a clear audit sentinel when absent — the column is NOT
        # NULL and "on_file" is unambiguous: funded from the on-file card.
        pm_db = payment.payment_method.to_s.empty? ? "on_file" : payment.payment_method
        sql = <<~SQL
          INSERT INTO #{schema}.payment_mandates
            (mandate_id, cart_mandate_id, user_id, agent_id, issuer,
             payment_method, amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)
          RETURNING id
        SQL
        insert_returning_id("Kiosk payment_mandate insert", sql, [
          payment.id, cart_row_id, payment.user_id, payment.agent_id, payment.issuer,
          pm_db, payment.amount_cents.to_i, payment.currency, payment.expires_at,
          payment.raw_jws,
        ])
      end

      # Inserts the settlement receipt row under the open SessionContext
      # (GUC-scoped transaction; no RLS policy on the mandate tables yet). The
      # PK is SERVER-generated; `cart_mandate_id` references the SERVER cart id
      # returned by phase 1 (`cart_row_id`), so the FK resolves. This is a
      # server-side settlement receipt (no agent-signed id), so there is no
      # `mandate_id`; `UNIQUE (cart_mandate_id)` is its idempotency anchor.
      # Returns the new settlement server id.
      def persist_settlement(cart_row_id:, cart:, settled:)
        schema = Kiosk.configuration.schema
        sql = <<~SQL
          INSERT INTO #{schema}.settlements
            (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, settled_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6, $7, now(), '')
          RETURNING id
        SQL
        insert_returning_id("Kiosk settlement insert", sql, [
          cart_row_id, cart.user_id, cart.agent_id, cart.issuer,
          settled[:psp_reference], settled[:settled_amount_cents].to_i, cart.currency,
        ])
      end

      # True when `error` is a DB unique-constraint violation. Matched by class
      # NAME, not constant: kiosk-server declares no activerecord/pg dependency
      # (the host Rails app provides them at call time), so naming
      # ActiveRecord::RecordNotUnique / PG::UniqueViolation directly would raise
      # NameError in the gem's own unit env. A standard optional-dependency
      # pattern.
      def unique_violation?(error)
        %w[ActiveRecord::RecordNotUnique PG::UniqueViolation].include?(error.class.name)
      end

      # Runs an `INSERT … RETURNING id` with BIND PARAMETERS and returns the
      # server-generated uuid PK.
      #
      # THE POINT (K-654). Every value the pay path writes travels as `$1…$N`,
      # OUT of the SQL text — so there is no `connection.quote` left to forget,
      # and no reading of a value as SQL is possible in the first place. The
      # helpers this replaced were heredocs with every field spliced through a
      # private `q()`; they were safe, but they were also the idiom the demos
      # ship as the reference others copy, which is why the engine could not
      # keep it after the demos gave it up.
      #
      # TYPES. Postgres infers each parameter's type from the INSERT's target
      # column (uuid / bigint / timestamptz / text), exactly as it inferred the
      # unknown-typed literals the interpolated form produced — so uuid columns
      # still reject a non-uuid, and a `Time` still lands as the same instant.
      # The single exception is `line_items`, whose argument is JSON text and
      # therefore carries an explicit `::jsonb` cast; see
      # {#persist_cart_mandate}. `spec/kiosk/server/executor_persistence_spec.rb`
      # asserts all three against a real Postgres, because none of it is
      # visible in the SQL text or to a FakeConnection.
      #
      # `exec_query`, NOT `exec_insert`: `exec_insert` rewrites the statement —
      # `sql_for_insert` looks the table's primary key up and appends its OWN
      # `RETURNING "id"` — which would both duplicate the clause these
      # statements already carry and cost a schema round trip.
      #
      # WHAT IS STILL INTERPOLATED, and why it is not the same thing: the
      # SCHEMA NAME (`Kiosk.configuration.schema`). That is an identifier the
      # operator sets in their own initializer, not a value any caller can
      # reach — an identifier cannot be a bind parameter in Postgres, so no
      # amount of binding would move it.
      #
      # @param name [String] statement label for the query log
      # @param sql [String] statement carrying `$N` placeholders and `RETURNING id`
      # @param binds [Array] one value per placeholder, in order
      # @return [String] the server-generated uuid primary key
      def insert_returning_id(name, sql, binds)
        connection.exec_query(sql, name, binds).to_a.first.fetch("id")
      end

      # ─── spending cap ───────────────────────────────────────

      # Raises Errors::SpendingCapExceeded when the acting assistant's cap would
      # be exceeded by this cart. No-op when no `config.spending_cap` seam is
      # configured or the assistant is uncapped (seam returns nil). Called inside
      # the phase-1 transaction BEFORE any persist, so a rejection rolls back and
      # never burns a mandate id or reaches the irreversible capture. cap 0 =
      # disabled. Best-effort at pay time (not a hard lock): a concurrent
      # double-spend could slip one charge over the cap — acceptable under the
      # metered-toll model.
      def enforce_spending_cap!(cart)
        seam = Kiosk.configuration.spending_cap
        return if seam.nil?

        cap = seam.call(agent_id: identity.agent_id)
        return if cap.nil? # this assistant is uncapped

        window_days = Kiosk.configuration.spending_cap_window_days
        # K-551: scope the tally to the cart's currency — summing cents across
        # currencies is meaningless (4999 USD is not within a 5000 EUR cap) and
        # a cross-currency sum could erode the cap.
        spent = settled_total_cents(agent_id: identity.agent_id, window_days: window_days,
                                    currency: cart.currency)
        return if spent + cart.total_amount_cents.to_i <= cap.to_i

        window_note = window_days ? " in the last #{window_days.to_i} day(s)" : ""
        raise Errors::SpendingCapExceeded.new(
          "assistant spending cap exceeded",
          hint: "cap #{cap.to_i} cents; #{spent} already settled#{window_note}; this charge is #{cart.total_amount_cents.to_i}",
        )
      end

      # Sums this agent's settled spend IN A SINGLE CURRENCY (optionally within a
      # rolling window of `window_days`) from the settlements receipt table,
      # under the open SessionContext. Scoping by currency keeps the tally
      # comparable to a same-currency cap (K-551) — cents are not fungible across
      # currencies. Returns cents (0 when the agent has settled nothing).
      def settled_total_cents(agent_id:, window_days:, currency:)
        schema = Kiosk.configuration.schema
        binds  = [agent_id, currency]
        # The window is a STATEMENT SHAPE, not a value: with no window there is
        # no predicate at all, so that stays a branch on the SQL text. The
        # number of days is a third BIND (`make_interval(days => $3)` rather
        # than the old `#{window_days.to_i} * INTERVAL '1 day'`), which is what
        # lets the last `connection.quote` in this file go.
        window = ""
        if window_days
          binds << window_days.to_i
          window = "AND settled_at >= now() - make_interval(days => $3)"
        end
        sql = <<~SQL
          SELECT COALESCE(SUM(settled_amount_cents), 0) AS total
          FROM #{schema}.settlements
          WHERE agent_id = $1 AND currency = $2 #{window}
        SQL
        connection.exec_query(sql, "Kiosk settled total", binds).to_a.first.fetch("total").to_i
      end

      # ─── helpers ───────────────────────────────────────────────────────

      def symbolize(value)
        case value
        when Hash then value.transform_keys { |k| k.to_sym }
        when nil  then {}
        else value
        end
      end
    end
  end
end
