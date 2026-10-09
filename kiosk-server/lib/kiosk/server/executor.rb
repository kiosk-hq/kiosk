# frozen_string_literal: true

require "kiosk/server/audit_sink"
require "kiosk/server/errors"
require "kiosk/server/failure_log"
require "kiosk/server/response_validation"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"
require "kiosk/server/queries"

module Kiosk
  module Server
    # Runs one call for an identity inside a {SessionContext}; returns a {Result} or raises {Errors::Base}.
    class Executor
      # The coarse kinds of call shared by the toll, the policy and this dispatcher; not wire paths.
      VERBS = %i[query run pay].freeze

      # Kinds with an irreversible external effect (a PSP capture) that manage their own transactions.
      SELF_MANAGED_VERBS = %i[pay].freeze

      # `name` is the query/action path segment; `pay` ignores it.
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

      # Emits one {ActionEvent} per action to the operator's audit sink. Outside the SessionContext,
      # so a rollback cannot erase the record and a sink cannot hold the transaction open.
      def audited(name, args)
        return yield unless AuditSink.configured?

        invoked_at = Time.now
        begin
          result = yield
        rescue StandardError => e
          emit(name, args, ActionEvent::ERROR, e, invoked_at)
          raise
        end
        emit(name, args, ActionEvent::OK, nil, invoked_at)
        result
      end

      # Only a registered action counts as invoked; an unknown name is about to answer 404.
      def emit(name, args, status, error, invoked_at)
        return if name.nil? || name.to_s.empty?
        return unless Actions.known.include?(name.to_s)

        # The args as the handler received them, with symbol keys.
        AuditSink.emit(
          ActionEvent.build(identity: identity, name: name.to_s, args: symbolize(args),
                            status: status, error: error, invoked_at: invoked_at),
        )
      end

      def dispatch(verb, args, name = nil)
        case verb
        when :query  then verb_query(args, name)
        when :run    then verb_run(args, name)
        when :pay    then verb_pay(args)
        end
      end

      # A handler returns rows or a {Page}; the page facts become the `Link` and `X-Total-Count` headers (§8.2).
      def verb_query(args, name = nil)
        args = symbolize(args)
        raise Errors::BadRequest, "query name required" if name.nil? || name.to_s.empty?

        handler = Queries.fetch(name)
        begin
          returned = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          report_handler_failure("Query", name, e)
          raise Errors::ActionFailed.new("Query #{name.inspect} failed",
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

      def verb_run(args, name = nil)
        args = symbolize(args)
        raise Errors::BadRequest, "action name required" if name.nil? || name.to_s.empty?

        handler = Actions.fetch(name)
        begin
          value = handler.call(args)
        rescue Errors::Base
          raise
        rescue StandardError => e
          report_handler_failure("Action", name, e)
          raise Errors::ActionFailed.new(
            "Action #{name.inspect} failed",
            hint: "See server logs for the backtrace.",
          )
        end

        validate_response!(Actions, :action, name, Result.new(kind: :value, payload: value))
      end

      # Checks the answer against the published `output_schema` when `validate_responses` is on.
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

      # Settles an AP2 cart. The PSP capture runs outside any transaction, between phases 1 and 3 (§11.6).
      def verb_pay(args)
        args = symbolize(args)

        # Whether this origin serves payments is answered before any argument is read.
        provider = Kiosk.configuration.payment_provider
        if provider.nil?
          raise Errors::ModuleNotServed.new(
            "this operator does not serve the payment module",
            hint: "`pay` is absent from this origin's capabilities; hand the transaction to your human",
          )
        end

        # Mandates are agent-signed, so a principal without an agent id cannot pay.
        if identity.agent_id.nil?
          raise Errors::Forbidden, "payment requires an agent identity (mandates are agent-signed)"
        end

        raw_intent   = args[:intent_mandate_jws]
        raw_cart     = args[:cart_mandate_jws]
        raw_payment  = args[:payment_mandate_jws]
        raise Errors::BadRequest, "args.intent_mandate_jws required"   if raw_intent.nil?  || raw_intent.to_s.empty?
        raise Errors::BadRequest, "args.cart_mandate_jws required"     if raw_cart.nil?    || raw_cart.to_s.empty?
        raise Errors::BadRequest, "args.payment_mandate_jws required"  if raw_payment.nil? || raw_payment.to_s.empty?

        # Refused before phase 1 so the mandate ids are not burned on a charge that cannot succeed.
        if provider.respond_to?(:setup_required?) && provider.setup_required?(user_id: identity.user_id)
          raise Errors::PaymentSetupRequired
        end

        # Phase 1: verify and persist the mandate chain. A unique violation means the chain was presented before.
        intent  = nil
        cart    = nil
        cart_row = nil
        payment = nil
        begin
          SessionContext.open(connection: connection, identity: identity) do
            intent  = MandateVerifier.verify_intent(raw_jws: raw_intent, identity: identity)
            cart    = MandateVerifier.verify_cart(raw_jws: raw_cart, identity: identity, intent: intent)
            # Before any persist or capture, so a refusal burns nothing.
            enforce_spending_cap!(cart)
            payment = MandateVerifier.verify_payment(raw_jws: raw_payment, identity: identity, cart: cart)
            intent_row = persist_intent_mandate(intent)
            cart_row   = persist_cart_mandate(cart, intent_row_id: intent_row)
            persist_payment_mandate(cart_row_id: cart_row, payment: payment)
          end
        rescue StandardError => e
          raise unless unique_violation?(e)

          # An identical, settled chain answers its settlement; anything else is a conflict, before any capture.
          replay = settled_replay(intent: intent, cart: cart, payment: payment)
          return replay if replay

          raise Errors::Conflict.new(
            "mandate already processed",
            hint: "this exact chain has no recorded settlement — it may still be in flight, or " \
                  "its capture may never have run. Do NOT sign a fresh chain on the strength of " \
                  "that: reconcile against the operator's own per-user query and re-sign only on " \
                  "a positive, unambiguous \"not paid\".",
          )
        end

        # Phase 2: the irreversible capture. A definitive decline is safe to retry; an unknown outcome is not.
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
                     "retry — first check `query my_orders` for this order's paid flag, and retry " \
                     "ONLY on a positive \"not paid\". A missing or pending record is not a \"not " \
                     "paid\": if you cannot confirm either way, stop and tell your human."
                 end
          raise Errors::PaymentFailed.new(e.message, hint: hint)
        end

        # Phase 3: record the settlement.
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

      # The settlement of an identical, already-settled chain, or nil. It writes nothing and runs
      # before the capture, so a replay can neither charge nor settle twice.
      def settled_replay(intent:, cart:, payment:)
        return nil if intent.nil? || cart.nil? || payment.nil?

        row = nil
        SessionContext.open(connection: connection, identity: identity) do
          row = settlement_for_chain(intent: intent, cart: cart, payment: payment)
        end
        return nil if row.nil?

        Result.new(kind: :value, payload: {
          settlement_id:        row.fetch("id"),
          psp_reference:        row.fetch("psp_reference"),
          settled_amount_cents: row.fetch("settled_amount_cents").to_i,
          currency:             row.fetch("currency"),
        })
      end

      # Byte-identical chain, scoped to the acting principal on every mandate row.
      def settlement_for_chain(intent:, cart:, payment:)
        schema = Kiosk.configuration.schema
        sql = <<~SQL
          SELECT s.id, s.psp_reference, s.settled_amount_cents, s.currency
          FROM #{schema}.settlements s
          JOIN #{schema}.cart_mandates    c ON c.id = s.cart_mandate_id
          JOIN #{schema}.intent_mandates  i ON i.id = c.intent_mandate_id
          JOIN #{schema}.payment_mandates p ON p.cart_mandate_id = c.id
          WHERE c.user_id = $1 AND i.user_id = $1 AND p.user_id = $1
            AND c.mandate_id = $2
            AND c.raw_jws = $3
            AND i.raw_jws = $4
            AND p.raw_jws = $5
          LIMIT 1
        SQL
        connection.exec_query(sql, "Kiosk settled replay lookup", [
          identity.user_id, cart.id, cart.raw_jws, intent.raw_jws, payment.raw_jws,
        ]).to_a.first
      end

      # The signed id goes to `mandate_id`; the row id is server-generated and returned.
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

      # References the server intent id; the signed intent-cart binding is checked by MandateVerifier.
      def persist_cart_mandate(cart, intent_row_id:)
        schema = Kiosk.configuration.schema
        # `line_items` arrives as JSON text; the cast stores a jsonb array rather than a string.
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

      def persist_payment_mandate(cart_row_id:, payment:)
        schema = Kiosk.configuration.schema
        # No presented payment method means the on-file card funded the charge.
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

      # Nobody signs a settlement, so it has no `mandate_id` or `raw_jws`; `UNIQUE (cart_mandate_id)` keeps it single.
      def persist_settlement(cart_row_id:, cart:, settled:)
        schema = Kiosk.configuration.schema
        sql = <<~SQL
          INSERT INTO #{schema}.settlements
            (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, settled_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, now())
          RETURNING id
        SQL
        insert_returning_id("Kiosk settlement insert", sql, [
          cart_row_id, cart.user_id, cart.agent_id, cart.issuer,
          settled[:psp_reference], settled[:settled_amount_cents].to_i, cart.currency,
        ])
      end

      # Matched by class name so neither ActiveRecord nor PG has to be loaded.
      def unique_violation?(error)
        %w[ActiveRecord::RecordNotUnique PG::UniqueViolation].include?(error.class.name)
      end

      # Every value is a bind parameter; only the operator-set schema name is interpolated.
      # `exec_query`, because `exec_insert` would append a second `RETURNING`.
      def insert_returning_id(name, sql, binds)
        connection.exec_query(sql, name, binds).to_a.first.fetch("id")
      end

      # Best-effort at pay time. A nil seam or a nil cap means uncapped.
      def enforce_spending_cap!(cart)
        seam = Kiosk.configuration.spending_cap
        return if seam.nil?

        cap = seam.call(agent_id: identity.agent_id)
        return if cap.nil? # this assistant is uncapped

        window_days = Kiosk.configuration.spending_cap_window_days
        # One tally per currency: cents are not fungible across currencies.
        spent = settled_total_cents(agent_id: identity.agent_id, window_days: window_days,
                                    currency: cart.currency)
        return if spent + cart.total_amount_cents.to_i <= cap.to_i

        window_note = window_days ? " in the last #{window_days.to_i} day(s)" : ""
        raise Errors::SpendingCapExceeded.new(
          "assistant spending cap exceeded",
          hint: "cap #{cap.to_i} cents; #{spent} already settled#{window_note}; this charge is #{cart.total_amount_cents.to_i}",
        )
      end

      # Settled cents for this agent in one currency, case-folded on both sides so `eur` and `EUR` are one tally.
      def settled_total_cents(agent_id:, window_days:, currency:)
        schema = Kiosk.configuration.schema
        binds  = [agent_id, MandateVerifier.canonical_currency(currency)]
        # No window means no predicate; the day count is still a bind.
        window = ""
        if window_days
          binds << window_days.to_i
          window = "AND settled_at >= now() - make_interval(days => $3)"
        end
        sql = <<~SQL
          SELECT COALESCE(SUM(settled_amount_cents), 0) AS total
          FROM #{schema}.settlements
          WHERE agent_id = $1 AND lower(btrim(currency)) = $2 #{window}
        SQL
        connection.exec_query(sql, "Kiosk settled total", binds).to_a.first.fetch("total").to_i
      end

      # The handler's message goes to the operator's log, never onto the wire.
      def report_handler_failure(kind, name, error)
        FailureLog.report("#{kind} #{name.inspect} raised #{error.class}", error)
      end

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
