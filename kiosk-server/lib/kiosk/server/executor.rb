# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"
require "kiosk/server/queries"

module Kiosk
  module Server
    # Central dispatcher. Receives a verb (one of {VERBS}) + args +
    # {Kiosk::Identity} + a database connection. Opens {SessionContext}
    # (transaction + four `SET LOCAL` GUCs per spec §6.3), routes to the
    # appropriate verb method, returns {Result} on success or raises
    # {Errors::Base} subclass on failure.
    #
    # See design spec §5.4 «Server side» — this implements the per-verb
    # dispatch that {WireController} wraps, factored out of the controller
    # so it's testable without Rails.
    class Executor
      # Spec §5.1: the fixed wire-surface verbs.
      VERBS = %i[query run pay schema events].freeze

      # Verbs that open their own transaction boundaries because they perform
      # an irreversible external side effect (a PSP capture) that a DB
      # ROLLBACK cannot undo. Everything else runs inside one wrapping
      # SessionContext; these manage their own SessionContext(s) instead.
      SELF_MANAGED_VERBS = %i[pay].freeze

      # Verbs that enumerate the in-process registry only — they need no
      # database connection and must NOT open a SessionContext.
      NO_DB_VERBS = %i[schema].freeze

      # The verbs that are actually implemented and advertised to agents.
      # `events` is stubbed and omitted intentionally.
      IMPLEMENTED_VERBS = %w[query run pay schema].freeze

      def self.call(kind:, args:, identity:, connection:)
        new(connection: connection, identity: identity).call(kind: kind, args: args)
      end

      attr_reader :connection, :identity

      def initialize(connection:, identity:)
        raise Errors::Unauthenticated, "identity required" if identity.nil?

        @connection = connection
        @identity   = identity
      end

      def call(kind:, args:)
        verb = kind.to_sym
        unless VERBS.include?(verb)
          raise Errors::BadRequest.new(
            "Unknown verb: #{kind.inspect}",
            hint: "Valid verbs: #{VERBS.inspect}",
          )
        end

        if NO_DB_VERBS.include?(verb)
          dispatch(verb, args) # catalog-only verbs — no DB or SessionContext needed
        elsif SELF_MANAGED_VERBS.include?(verb)
          dispatch(verb, args) # the verb manages its own SessionContext(s)
        else
          SessionContext.open(connection: connection, identity: identity) do
            dispatch(verb, args)
          end
        end
      end

      private

      def dispatch(verb, args)
        case verb
        when :query  then verb_query(args)
        when :run    then verb_run(args)
        when :pay    then verb_pay(args)
        when :schema then verb_schema(args)
        when :events then verb_events(args)
        end
      end

      # ─── query ─────────────────────────────────────────────────────────

      def verb_query(args)
        args = symbolize(args)
        name = args.delete(:name)
        raise Errors::BadRequest, "args.name (query) required" if name.nil? || name.to_s.empty?

        handler = Queries.fetch(name)
        begin
          rows = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          raise Errors::ActionFailed.new("Query #{name.inspect} raised #{e.class}: #{e.message}",
                                         hint: "See server logs for the backtrace.")
        end
        Result.new(kind: :rows, payload: rows)
      end

      # ─── run ───────────────────────────────────────────────────────────

      def verb_run(args)
        args = symbolize(args)
        name = args.delete(:name) || args.delete(:action)
        raise Errors::BadRequest, "args.name (action) required" if name.nil? || name.to_s.empty?

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

        Result.new(kind: :value, payload: value)
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
      #       idempotency by cart.id. FAIL ⇒ trail persisted, no charge; safe
      #                               to retry (idempotency key).
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
        settled = begin
          provider.capture(cart, payment_method: payment.payment_method)
        rescue Kiosk::PaymentProviders::SetupRequired
          raise Errors::PaymentSetupRequired
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
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.intent_mandates
            (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
             currency, expires_at, created_at, raw_jws)
          VALUES (#{q(intent.id)}, #{q(intent.user_id)}, #{q(intent.agent_id)},
             #{q(intent.issuer)}, #{q(intent.scope)}, #{intent.cap_amount_cents.to_i},
             #{q(intent.currency)}, #{q(intent.expires_at)}, now(), #{q(intent.raw_jws)})
          RETURNING id
        SQL
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
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.cart_mandates
            (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
             total_amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES (#{q(cart.id)}, #{q(intent_row_id)}, #{q(cart.user_id)},
             #{q(cart.agent_id)}, #{q(cart.issuer)}, #{q(cart.line_items.to_json)}::jsonb,
             #{cart.total_amount_cents.to_i}, #{q(cart.currency)}, #{q(cart.expires_at)},
             now(), #{q(cart.raw_jws)})
          RETURNING id
        SQL
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
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.payment_mandates
            (mandate_id, cart_mandate_id, user_id, agent_id, issuer,
             payment_method, amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES (#{q(payment.id)}, #{q(cart_row_id)}, #{q(payment.user_id)},
             #{q(payment.agent_id)}, #{q(payment.issuer)}, #{q(pm_db)},
             #{payment.amount_cents.to_i}, #{q(payment.currency)}, #{q(payment.expires_at)},
             now(), #{q(payment.raw_jws)})
          RETURNING id
        SQL
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
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.settlements
            (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, settled_at, raw_jws)
          VALUES (#{q(cart_row_id)}, #{q(cart.user_id)}, #{q(cart.agent_id)},
             #{q(cart.issuer)}, #{q(settled[:psp_reference])}, #{settled[:settled_amount_cents].to_i},
             #{q(cart.currency)}, now(), '')
          RETURNING id
        SQL
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

      def q(value) = connection.quote(value)

      # ─── schema ────────────────────────────────────────────────────────

      # Returns the provider's in-process catalog so an agent can self-discover
      # available queries and actions without relying solely on a static skill file.
      # Never opens a SessionContext or touches the DB.
      def verb_schema(_args)
        Result.new(kind: :value, payload: {
          verbs:   IMPLEMENTED_VERBS,
          queries: Queries.catalog,
          actions: Actions.catalog,
        })
      end

      # ─── stub — lands in a follow-up release ───────────────────────────

      def verb_events(_args)
        raise NotImplementedError,
              "`events` verb arrives in a follow-up release (NDJSON streaming per §5.8)"
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
