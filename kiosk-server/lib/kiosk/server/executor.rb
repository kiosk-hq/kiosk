# frozen_string_literal: true

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
        raise Errors::Unauthenticated, 'identity required' if identity.nil?

        @connection = connection
        @identity   = identity
      end

      def call(kind:, args:, name: nil)
        verb = kind.to_sym
        raise Errors::BadRequest.new("Unknown verb: #{kind.inspect}", hint: "Valid verbs: #{VERBS.inspect}") unless VERBS.include?(verb)
        # A self-managed verb opens its own SessionContext(s).
        return dispatch(verb, args, name) if SELF_MANAGED_VERBS.include?(verb)
        return audited(name, args) { in_session { dispatch(verb, args, name) } } if verb == :run

        in_session { dispatch(verb, args, name) }
      end

      private

      def in_session(&) = SessionContext.open(connection: connection, identity: identity, &)

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
                            status: status, error: error, invoked_at: invoked_at)
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
        raise Errors::BadRequest, 'query name required' if name.nil? || name.to_s.empty?

        returned = invoke('Query', Queries.fetch(name), name, args)
        validate_response!(Queries, :query, name, rows_result(returned))
      end

      def rows_result(returned)
        return Result.new(kind: :rows, payload: returned) unless returned.is_a?(Page)

        Result.new(kind: :rows, payload: returned.rows, next_cursor: returned.next_cursor, total: returned.total)
      end

      def verb_run(args, name = nil)
        args = symbolize(args)
        raise Errors::BadRequest, 'action name required' if name.nil? || name.to_s.empty?

        value = invoke('Action', Actions.fetch(name), name, args)
        validate_response!(Actions, :action, name, Result.new(kind: :value, payload: value))
      end

      # The handler's answer. A Kiosk error passes through; any other error is logged and answers `action_failed`.
      def invoke(label, handler, name, args)
        handler.call(args)
      rescue Errors::Base
        raise
      rescue StandardError => e
        report_handler_failure(label, name, e)
        raise Errors::ActionFailed.new("#{label} #{name.inspect} failed", hint: 'See server logs for the backtrace.')
      end

      # Checks the answer against the published `output_schema` when `validate_responses` is on.
      def validate_response!(registry, kind, name, result)
        return result unless Kiosk.configuration.validate_responses

        ResponseValidation.validate_payload!(
          result.to_payload,
          output_schema: registry.describe(name)[:output_schema],
          verb: name.to_s,
          kind: kind
        )
        result
      end

      # The handler's message goes to the operator's log, never onto the wire.
      def report_handler_failure(kind, name, error)
        FailureLog.report("#{kind} #{name.inspect} raised #{error.class}", error)
      end

      def symbolize(value)
        case value
        when Hash then value.transform_keys(&:to_sym)
        when nil  then {}
        else value
        end
      end

      # The `pay` verb: settles an AP2 cart. The PSP capture runs outside any transaction,
      # between phases 1 and 3 (§11.6).
      module Pay
        RETRYABLE_HINT = 'the charge did not go through; no money moved. The human may need to ' \
                         'update the payment method (payment_setup), then retry pay.'
        UNKNOWN_HINT   = 'the charge status is UNKNOWN (the processor did not confirm). Do NOT blindly ' \
                         "retry — first check `query my_orders` for this order's paid flag, and retry " \
                         'ONLY on a positive "not paid". A missing or pending record is not a "not ' \
                         'paid": if you cannot confirm either way, stop and tell your human.'
        CONFLICT_HINT  = 'this exact chain has no recorded settlement — it may still be in flight, or ' \
                         'its capture may never have run. Do NOT sign a fresh chain on the strength of ' \
                         "that: reconcile against the operator's own per-user query and re-sign only on " \
                         'a positive, unambiguous "not paid".'

        # The verified mandates and the cart row they were persisted under.
        Chain = Struct.new(:intent, :cart, :payment, :cart_row)

        private

        def verb_pay(args)
          args = symbolize(args)
          # Whether this origin serves payments is answered before any argument is read.
          provider = payment_provider!
          raws = pay_mandates!(args)
          # Refused before phase 1 so the mandate ids are not burned on a charge that cannot succeed.
          raise Errors::PaymentSetupRequired if provider.respond_to?(:setup_required?) && provider.setup_required?(user_id: identity.user_id)

          chain = persist_chain(raws)
          return chain if chain.is_a?(Result)

          settle(chain, capture(provider, chain))
        end

        def payment_provider!
          provider = Kiosk.configuration.payment_provider
          return provider unless provider.nil?

          raise Errors::ModuleNotServed.new(
            'this operator does not serve the payment module',
            hint: "`pay` is absent from this origin's capabilities; hand the transaction to your human"
          )
        end

        # The three signed mandates from the args, by part.
        def pay_mandates!(args)
          # Mandates are agent-signed, so a principal without an agent id cannot pay.
          raise Errors::Forbidden, 'payment requires an agent identity (mandates are agent-signed)' if identity.agent_id.nil?

          %i[intent cart payment].to_h do |part|
            raw = args[:"#{part}_mandate_jws"]
            raise Errors::BadRequest, "args.#{part}_mandate_jws required" if raw.nil? || raw.to_s.empty?

            [part, raw]
          end
        end

        # Phase 1: verify and persist the mandate chain. A unique violation means the chain was presented
        # before: an identical, settled chain answers its settlement; anything else is a conflict, before any capture.
        def persist_chain(raws)
          chain = Chain.new
          verify_and_persist(chain, raws)
        rescue StandardError => e
          raise unless unique_violation?(e)

          settled_replay(intent: chain.intent, cart: chain.cart, payment: chain.payment) or
            raise Errors::Conflict.new('mandate already processed', hint: CONFLICT_HINT)
        end

        def verify_and_persist(chain, raws)
          SessionContext.open(connection: connection, identity: identity) do
            cart = verify_intent_and_cart(chain, raws)
            # Before any persist or capture, so a refusal burns nothing.
            enforce_spending_cap!(cart)
            chain.payment  = MandateVerifier.verify_payment(raw_jws: raws[:payment], identity: identity, cart: cart)
            chain.cart_row = persist_mandates(chain)
          end
          chain
        end

        def verify_intent_and_cart(chain, raws)
          chain.intent = MandateVerifier.verify_intent(raw_jws: raws[:intent], identity: identity)
          chain.cart   = MandateVerifier.verify_cart(raw_jws: raws[:cart], identity: identity, intent: chain.intent)
        end

        # The cart row id.
        def persist_mandates(chain)
          intent_row = persist_intent_mandate(chain.intent)
          cart_row   = persist_cart_mandate(chain.cart, intent_row_id: intent_row)
          persist_payment_mandate(cart_row_id: cart_row, payment: chain.payment)
          cart_row
        end

        # Phase 2: the irreversible capture. A definitive decline is safe to retry; an unknown outcome is not.
        def capture(provider, chain)
          provider.capture(chain.cart, payment_method: chain.payment.payment_method)
        rescue Kiosk::PaymentProviders::SetupRequired
          raise Errors::PaymentSetupRequired
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          raise Errors::PaymentFailed.new(e.message, hint: e.retryable? ? RETRYABLE_HINT : UNKNOWN_HINT)
        end

        # Phase 3: record the settlement.
        def settle(chain, settled)
          settlement_id = nil
          SessionContext.open(connection: connection, identity: identity) do
            settlement_id = persist_settlement(cart_row_id: chain.cart_row, cart: chain.cart, settled: settled)
          end
          settlement_result(settlement_id, settled[:psp_reference], settled[:settled_amount_cents], chain.cart.currency)
        end

        def settlement_result(settlement_id, psp_reference, settled_amount_cents, currency)
          Result.new(kind: :value, payload: { settlement_id:, psp_reference:, settled_amount_cents:, currency: })
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

          settlement_result(row.fetch('id'), row.fetch('psp_reference'), row.fetch('settled_amount_cents').to_i, row.fetch('currency'))
        end
      end

      # The assistant's spending cap, checked at pay time.
      module SpendingCap
        private

        # A nil seam or a nil cap means uncapped. Runs in the transaction that
        # persists the cart, under a per-assistant lock, so two concurrent pays
        # see each other: the second counts the first's cart as in flight.
        def enforce_spending_cap!(cart)
          cap = Kiosk.configuration.spending_cap&.call(agent_id: identity.agent_id)
          return if cap.nil? # this assistant is uncapped

          window_days = Kiosk.configuration.spending_cap_window_days
          spent = spent_in_window(cart, window_days)
          return if spent + cart.total_amount_cents.to_i <= cap.to_i

          raise Errors::SpendingCapExceeded.new('assistant spending cap exceeded', hint: cap_hint(cap, spent, window_days, cart))
        end

        # One tally per currency: cents are not fungible across currencies.
        def spent_in_window(cart, window_days)
          agent_id = identity.agent_id
          lock_assistant_payments!(agent_id)
          settled_total_cents(agent_id:, window_days:, currency: cart.currency) +
            in_flight_total_cents(agent_id:, currency: cart.currency)
        end

        def cap_hint(cap, spent, window_days, cart)
          window_note = window_days ? " in the last #{window_days.to_i} day(s)" : ''
          "cap #{cap.to_i} cents; #{spent} already settled or in flight#{window_note}; " \
            "this charge is #{cart.total_amount_cents.to_i}"
        end

        # Carts of this agent whose mandate is live and that have no settlement:
        # a capture may still be running for each.
        def in_flight_total_cents(agent_id:, currency:)
          schema = Kiosk.configuration.schema
          sql = <<~SQL
            SELECT COALESCE(SUM(c.total_amount_cents), 0) AS total
            FROM #{schema}.cart_mandates c
            WHERE c.agent_id = $1 AND lower(btrim(c.currency)) = $2 AND c.expires_at > now()
              AND NOT EXISTS (SELECT 1 FROM #{schema}.settlements s WHERE s.cart_mandate_id = c.id)
          SQL
          binds = [agent_id, MandateVerifier.canonical_currency(currency)]
          connection.exec_query(sql, 'Kiosk in-flight total', binds).to_a.first.fetch('total').to_i
        end

        # Held to the end of the transaction; an advisory lock needs no grant on any table.
        def lock_assistant_payments!(agent_id)
          connection.exec_query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
                                'Kiosk spending cap lock', [agent_id.to_s])
        end
      end

      # The mandate and settlement rows. Every value is a bind parameter; only the
      # operator-set schema name is interpolated.
      module Ledger
        # Byte-identical chain, scoped to the acting principal on every mandate row.
        CHAIN_SETTLEMENT_SQL = <<~SQL
          SELECT s.id, s.psp_reference, s.settled_amount_cents, s.currency
          FROM %<schema>s.settlements s
          JOIN %<schema>s.cart_mandates    c ON c.id = s.cart_mandate_id
          JOIN %<schema>s.intent_mandates  i ON i.id = c.intent_mandate_id
          JOIN %<schema>s.payment_mandates p ON p.cart_mandate_id = c.id
          WHERE c.user_id = $1 AND i.user_id = $1 AND p.user_id = $1
            AND c.mandate_id = $2
            AND c.raw_jws = $3
            AND i.raw_jws = $4
            AND p.raw_jws = $5
          LIMIT 1
        SQL

        # The signed id goes to `mandate_id`; the row id is server-generated and returned.
        INTENT_INSERT_SQL = <<~SQL
          INSERT INTO %<schema>s.intent_mandates
            (mandate_id, user_id, agent_id, issuer, scope, cap_amount_cents,
             currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9)
          RETURNING id
        SQL

        # `line_items` arrives as JSON text; the cast stores a jsonb array rather than a string.
        CART_INSERT_SQL = <<~SQL
          INSERT INTO %<schema>s.cart_mandates
            (mandate_id, intent_mandate_id, user_id, agent_id, issuer, line_items,
             total_amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)
          RETURNING id
        SQL

        PAYMENT_INSERT_SQL = <<~SQL
          INSERT INTO %<schema>s.payment_mandates
            (mandate_id, cart_mandate_id, user_id, agent_id, issuer,
             payment_method, amount_cents, currency, expires_at, created_at, raw_jws)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)
          RETURNING id
        SQL

        # Nobody signs a settlement, so it has no `mandate_id` or `raw_jws`; `UNIQUE (cart_mandate_id)` keeps it single.
        SETTLEMENT_INSERT_SQL = <<~SQL
          INSERT INTO %<schema>s.settlements
            (cart_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, settled_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, now())
          RETURNING id
        SQL

        private

        def settlement_for_chain(intent:, cart:, payment:)
          connection.exec_query(ledger_sql(CHAIN_SETTLEMENT_SQL), 'Kiosk settled replay lookup', [
                                  identity.user_id, cart.id, cart.raw_jws, intent.raw_jws, payment.raw_jws
                                ]).to_a.first
        end

        def persist_intent_mandate(intent)
          insert_returning_id('Kiosk intent_mandate insert', INTENT_INSERT_SQL, [
                                intent.id, intent.user_id, intent.agent_id, intent.issuer, intent.scope,
                                intent.cap_amount_cents.to_i, intent.currency, intent.expires_at, intent.raw_jws
                              ])
        end

        # References the server intent id; the signed intent-cart binding is checked by MandateVerifier.
        def persist_cart_mandate(cart, intent_row_id:)
          insert_returning_id('Kiosk cart_mandate insert', CART_INSERT_SQL, [
                                cart.id, intent_row_id, cart.user_id, cart.agent_id, cart.issuer,
                                cart.line_items.to_json, cart.total_amount_cents.to_i, cart.currency,
                                cart.expires_at, cart.raw_jws
                              ])
        end

        def persist_payment_mandate(cart_row_id:, payment:)
          # No presented payment method means the on-file card funded the charge.
          pm_db = payment.payment_method.to_s.empty? ? 'on_file' : payment.payment_method
          insert_returning_id('Kiosk payment_mandate insert', PAYMENT_INSERT_SQL, [
                                payment.id, cart_row_id, payment.user_id, payment.agent_id, payment.issuer,
                                pm_db, payment.amount_cents.to_i, payment.currency, payment.expires_at,
                                payment.raw_jws
                              ])
        end

        def persist_settlement(cart_row_id:, cart:, settled:)
          insert_returning_id('Kiosk settlement insert', SETTLEMENT_INSERT_SQL, [
                                cart_row_id, cart.user_id, cart.agent_id, cart.issuer,
                                settled[:psp_reference], settled[:settled_amount_cents].to_i, cart.currency
                              ])
        end

        # Settled cents for this agent in one currency, case-folded on both sides so `eur` and `EUR` are one tally.
        def settled_total_cents(agent_id:, window_days:, currency:)
          binds = [agent_id, MandateVerifier.canonical_currency(currency)]
          # No window means no predicate; the day count is still a bind.
          binds << window_days.to_i if window_days
          window = window_days ? 'AND settled_at >= now() - make_interval(days => $3)' : ''
          sql = <<~SQL
            SELECT COALESCE(SUM(settled_amount_cents), 0) AS total
            FROM #{Kiosk.configuration.schema}.settlements
            WHERE agent_id = $1 AND lower(btrim(currency)) = $2 #{window}
          SQL
          connection.exec_query(sql, 'Kiosk settled total', binds).to_a.first.fetch('total').to_i
        end

        # Matched by class name so neither ActiveRecord nor PG has to be loaded.
        def unique_violation?(error)
          %w[ActiveRecord::RecordNotUnique PG::UniqueViolation].include?(error.class.name)
        end

        def ledger_sql(template) = format(template, schema: Kiosk.configuration.schema)

        # `exec_query`, because `exec_insert` would append a second `RETURNING`.
        def insert_returning_id(name, template, binds)
          connection.exec_query(ledger_sql(template), name, binds).to_a.first.fetch('id')
        end
      end

      include Pay
      include SpendingCap
      include Ledger
    end
  end
end
