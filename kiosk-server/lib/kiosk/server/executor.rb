# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"

module Kiosk
  module Server
    # Central dispatcher. Receives a verb (one of {VERBS}) + args +
    # {Kiosk::Identity} + a database connection. Opens {SessionContext}
    # (transaction + four `SET LOCAL` GUCs per spec §6.3), routes to the
    # appropriate verb method, returns {Result} on success or raises
    # {Errors::Base} subclass on failure.
    #
    # See design spec §5.4 «Server side» — this implements the
    # `Kiosk::ExecController#exec` pseudocode shown there, factored out of
    # the controller so it's testable without Rails.
    class Executor
      # Spec §5.1: the fixed six-verb wire surface.
      VERBS = %i[sql run pay schema help events].freeze

      # Verbs that open their own transaction boundaries because they perform
      # an irreversible external side effect (a PSP capture) that a DB
      # ROLLBACK cannot undo. Everything else runs inside one wrapping
      # SessionContext; these manage their own SessionContext(s) instead.
      SELF_MANAGED_VERBS = %i[pay].freeze

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

        if SELF_MANAGED_VERBS.include?(verb)
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
        when :sql    then verb_sql(args)
        when :run    then verb_run(args)
        when :pay    then verb_pay(args)
        when :schema then verb_schema(args)
        when :help   then verb_help(args)
        when :events then verb_events(args)
        end
      end

      # ─── sql ───────────────────────────────────────────────────────────

      def verb_sql(args)
        sql = string_arg(args, :sql)
        raise Errors::BadRequest, "args.sql required" if sql.nil? || sql.empty?

        rows = connection.execute(sql)
        Result.new(kind: :rows, payload: rows_to_array(rows))
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
            hint: "See server logs (action_log row) for full backtrace.",
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
      #   P1  verify + persist the mandate trail (RLS-scoped tx). No external
      #       effect yet.            FAIL ⇒ nothing charged, rows rolled back.
      #   P2  irreversible PSP capture, OUTSIDE any DB transaction, keyed for
      #       idempotency by cart.id. FAIL ⇒ trail persisted, no charge; safe
      #                               to retry (idempotency key).
      #   P3  record the settlement (fresh RLS-scoped tx).
      #       FAIL ⇒ charge + trail exist, payment row missing — reconcilable
      #              from the cart row + idempotency key, never a silent
      #              double-charge.
      def verb_pay(args)
        args        = symbolize(args)
        raw_intent  = args[:intent_mandate_jws]
        raw_cart    = args[:cart_mandate_jws]
        raise Errors::BadRequest, "args.intent_mandate_jws required" if raw_intent.nil? || raw_intent.to_s.empty?
        raise Errors::BadRequest, "args.cart_mandate_jws required"   if raw_cart.nil?   || raw_cart.to_s.empty?

        provider = Kiosk.configuration.payment_provider
        raise Errors::Forbidden, "no payment_provider configured" if provider.nil?

        # Phase 1 — verify + persist the mandate trail (RLS-scoped tx).
        cart = nil
        SessionContext.open(connection: connection, identity: identity) do
          intent = MandateVerifier.verify_intent(raw_jws: raw_intent, identity: identity)
          cart   = MandateVerifier.verify_cart(raw_jws: raw_cart, identity: identity, intent: intent)
          persist_intent_mandate(intent)
          persist_cart_mandate(cart)
        end

        # Phase 2 — irreversible external capture. OUTSIDE any DB transaction.
        settled = provider.capture(cart)

        # Phase 3 — record settlement (fresh RLS-scoped tx).
        payment_id = nil
        SessionContext.open(connection: connection, identity: identity) do
          payment_id = persist_payment_mandate(cart: cart, settled: settled)
        end

        Result.new(kind: :value, payload: {
          payment_mandate_id:   payment_id,
          psp_reference:        settled[:psp_reference],
          settled_amount_cents: settled[:settled_amount_cents],
          currency:             cart.currency,
        })
      end

      # Inserts the intent-mandate row under the open SessionContext
      # (RLS-scoped). The mandate's own signed id is the PK, so the cart and
      # payment rows can reference it by id and the trail is auditable
      # end-to-end. Plain INSERT … RETURNING id (no ON CONFLICT — the PK is
      # supplied, so the dead ON CONFLICT path is gone). Returns the id.
      def persist_intent_mandate(intent)
        schema = Kiosk.configuration.schema
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.intent_mandates
            (id, user_id, agent_id, issuer, scope, cap_amount_cents,
             currency, expires_at, created_at, raw_jws)
          VALUES (#{q(intent.id)}, #{q(intent.user_id)}, #{q(intent.agent_id)},
             #{q(intent.issuer)}, #{q(intent.scope)}, #{intent.cap_amount_cents.to_i},
             #{q(intent.currency)}, now() + interval '1 hour', now(), #{q(intent.raw_jws)})
          RETURNING id
        SQL
      end

      # Inserts the cart-mandate row under the open SessionContext
      # (RLS-scoped). PK = the cart's signed id; intent_mandate_id references
      # the intent row persisted in phase 1. Plain INSERT … RETURNING id (no
      # ON CONFLICT). Returns the id.
      def persist_cart_mandate(cart)
        schema = Kiosk.configuration.schema
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.cart_mandates
            (id, intent_mandate_id, user_id, agent_id, issuer, line_items,
             total_amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES (#{q(cart.id)}, #{q(cart.intent_mandate_id)}, #{q(cart.user_id)},
             #{q(cart.agent_id)}, #{q(cart.issuer)}, #{q(cart.line_items.to_json)}::jsonb,
             #{cart.total_amount_cents.to_i}, #{q(cart.currency)}, now() + interval '1 hour',
             now(), #{q(cart.raw_jws)})
          RETURNING id
        SQL
      end

      # Inserts the payment-mandate row under the open SessionContext
      # (RLS-scoped). cart_mandate_id references the cart row persisted in
      # phase 1 by its known id, so the FK resolves. Returns the new
      # payment_mandate id.
      def persist_payment_mandate(cart:, settled:)
        schema = Kiosk.configuration.schema
        connection.execute(<<~SQL).to_a.first.fetch("id")
          INSERT INTO #{schema}.payment_mandates
            (id, cart_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, settled_at, raw_jws)
          VALUES (gen_random_uuid(), #{q(cart.id)}, #{q(cart.user_id)}, #{q(cart.agent_id)},
             #{q(cart.issuer)}, #{q(settled[:psp_reference])}, #{settled[:settled_amount_cents].to_i},
             #{q(cart.currency)}, now(), '')
          RETURNING id
        SQL
      end

      def q(value) = connection.quote(value)

      # ─── stubs — land in follow-up releases ────────────────────────────

      def verb_schema(_args)
        raise NotImplementedError,
              "`schema` verb arrives in a follow-up release (Postgres introspection)"
      end

      def verb_help(_args)
        raise NotImplementedError,
              "`help` verb arrives in a follow-up release (reads COMMENT ON TABLE/ACTION)"
      end

      def verb_events(_args)
        raise NotImplementedError,
              "`events` verb arrives in a follow-up release (NDJSON streaming per §5.8)"
      end

      # ─── helpers ───────────────────────────────────────────────────────

      def string_arg(args, key)
        return args.to_s if args.is_a?(String)

        h = symbolize(args)
        h[key]&.to_s
      end

      def symbolize(value)
        case value
        when Hash then value.transform_keys { |k| k.to_sym }
        when nil  then {}
        else value
        end
      end

      def rows_to_array(rows)
        # PG::Result responds to #to_a and yields Hash rows. Fake
        # connections in tests return Array<Hash> directly. Accept both.
        rows.respond_to?(:to_a) ? rows.to_a : Array(rows)
      end
    end
  end
end
