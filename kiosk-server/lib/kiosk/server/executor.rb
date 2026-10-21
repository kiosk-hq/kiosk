# frozen_string_literal: true

module Kiosk
  module Server
    # Runs one call for an identity inside a {SessionContext}; returns a {Result} or raises {Errors::Base}.
    class Executor
      # The coarse kinds of call shared by the toll, the policy and this dispatcher; not HTTP paths.
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

      # `handler` answers in place of the registered one.
      def call(kind:, args:, name: nil, handler: nil)
        verb = kind.to_sym
        raise Errors::BadRequest.new("Unknown verb: #{kind.inspect}", hint: "Valid verbs: #{VERBS.inspect}") unless VERBS.include?(verb)
        # A self-managed verb opens its own SessionContext(s).
        return dispatch(verb, args, name, handler) if SELF_MANAGED_VERBS.include?(verb)
        return audited(name, args) { in_session { dispatch(verb, args, name, handler) } } if verb == :run

        in_session { dispatch(verb, args, name, handler) }
      end

      private

      def in_session(&) = SessionContext.open(connection: connection, identity: identity, &)

      # Emits one {ActionEvent} per action to the operator's audit sink. Outside the SessionContext,
      # so a rollback cannot erase the record and a sink cannot hold the transaction open.
      def audited(name, args)
        return yield unless AuditSink.configured?

        invoked_at = Time.current
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

      def dispatch(verb, args, name, handler)
        case verb
        when :query  then verb_query(args, name, handler)
        when :run    then verb_run(args, name, handler)
        when :pay    then verb_pay(args)
        end
      end

      # A handler returns rows or a {Page}; the page facts become the `Link` and `X-Total-Count` headers (§8.2).
      def verb_query(args, name, handler)
        args = symbolize(args)
        raise Errors::BadRequest, 'query name required' if name.nil? || name.to_s.empty?

        returned = invoke('Query', handler || Queries.fetch(name), name, args)
        validate_response!(Queries, :query, name, rows_result(returned))
      end

      def rows_result(returned)
        return Result.new(kind: :rows, payload: returned) unless returned.is_a?(Page)

        Result.new(kind: :rows, payload: returned.rows, next_cursor: returned.next_cursor, total: returned.total)
      end

      def verb_run(args, name, handler)
        args = symbolize(args)
        raise Errors::BadRequest, 'action name required' if name.nil? || name.to_s.empty?

        value = invoke('Action', handler || Actions.fetch(name), name, args)
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

      # The handler's message goes to the operator's log, never onto the protocol.
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

      # The `pay` verb: settles an operator-signed checkout through two closed AP2
      # mandates. The PSP capture runs outside any transaction, between phases 1 and 3 (§11.6).
      module Pay
        RETRYABLE_HINT = 'the charge did not go through and no money moved. The human may need to ' \
                         'update the payment method (payment_setup). Then sign new mandates and pay again.'
        UNKNOWN_HINT   = 'the payment provider did not confirm the charge, so its status is unknown. ' \
                         'Send the SAME two mandates again, byte for byte: this operator charges one pair ' \
                         'at most once. Do not sign new mandates.'
        CONFLICT_HINT  = 'this operator will not charge these mandates: an earlier call with them was ' \
                         'declined, or another pair for this checkout is settled or still in progress. ' \
                         "Before you sign new mandates, read the order's paid state through the operator's " \
                         'own query, and sign new ones only on a clear "not paid".'

        # The verified mandates, the checkout row they were persisted under, and
        # whether an earlier call already persisted them.
        Chain = Struct.new(:checkout, :payment, :checkout_row, :repeat)

        private

        def verb_pay(args)
          args = symbolize(args)
          # Whether this origin serves payments is answered before any argument is read.
          provider = payment_provider!
          raws = pay_mandates!(args)
          # Refused before phase 1, so the checkout is not held by a charge that cannot succeed.
          raise Errors::PaymentSetupRequired if provider.respond_to?(:setup_required?) && provider.setup_required?(user_id: identity.user_id)

          chain = persist_chain(raws)
          return chain if chain.is_a?(Result)

          settle(provider, chain, capture(provider, chain))
        end

        def payment_provider!
          provider = Kiosk.configuration.payment_provider
          return provider unless provider.nil?

          raise Errors::ModuleNotServed.new(
            'this operator does not serve the payment module',
            hint: "`pay` is absent from this origin's capabilities; hand the transaction to your human"
          )
        end

        # The two signed mandates from the args, by part.
        def pay_mandates!(args)
          # Mandates are agent-signed, so a principal without an agent id cannot pay.
          raise Errors::Forbidden, 'payment requires an agent identity (mandates are agent-signed)' if identity.agent_id.nil?

          %i[checkout payment].to_h do |part|
            raw = args[:"#{part}_mandate"]
            raise Errors::BadRequest, "args.#{part}_mandate required" if raw.nil? || raw.to_s.empty?

            [part, raw]
          end
        end

        # Phase 1: verify and persist the mandates. A unique violation means they, or another
        # live pair for the same checkout, were presented before.
        def persist_chain(raws)
          chain = Chain.new
          verify_and_persist(chain, raws)
        rescue StandardError => e
          raise unless unique_violation?(e)

          repeat(chain)
        end

        def verify_and_persist(chain, raws)
          SessionContext.open(connection: connection, identity: identity) do
            chain.checkout = MandateVerifier.verify_checkout(sd_jwt: raws[:checkout], identity: identity)
            # Before any persist or capture, so a refusal holds nothing.
            enforce_spending_cap!(chain.checkout)
            chain.payment      = MandateVerifier.verify_payment(sd_jwt: raws[:payment], identity: identity, checkout: chain.checkout)
            chain.checkout_row = persist_mandates(chain)
          end
          chain
        end

        # The checkout row id.
        def persist_mandates(chain)
          checkout_row = persist_checkout_mandate(chain.checkout)
          persist_payment_mandate(checkout_row_id: checkout_row, payment: chain.payment)
          checkout_row
        end

        # Phase 2: the irreversible capture. A refusal under which no money moved
        # declines the checkout mandate, so it stops counting against the spending cap.
        def capture(provider, chain)
          charge(provider, chain)
        rescue Kiosk::PaymentProviders::SetupRequired
          decline(chain)
          raise Errors::PaymentSetupRequired
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          decline(chain) if e.retryable?
          raise Errors::PaymentFailed.new(e.message, hint: e.retryable? ? RETRYABLE_HINT : UNKNOWN_HINT)
        rescue Errors::Forbidden, Errors::BadRequest
          decline(chain)
          raise
        end

        # A repeated pair resumes its capture under the same idempotency key.
        def charge(provider, chain)
          method = chain.repeat ? :resume : :capture
          provider.public_send(method, chain.checkout, payment_method: chain.payment.payment_instrument)
        end

        # Phase 3: record the settlement, then tell the provider, so the
        # operator's work after the payment reads the settlement. A concurrent
        # call that settled the same checkout first answers with its settlement.
        def settle(provider, chain, settled)
          settlement_id = record_settlement(chain, settled)
          provider.settled(chain.checkout) if provider.respond_to?(:settled)
          settlement_result(chain, settlement_id, settled, chain.checkout.currency)
        rescue StandardError => e
          row = unique_violation?(e) && recorded_chain(chain)
          raise unless row && row['settlement_id']

          stored_settlement(chain, row)
        end

        # The settlement row's id.
        def record_settlement(chain, settled)
          SessionContext.open(connection: connection, identity: identity) do
            persist_settlement(checkout_row_id: chain.checkout_row, checkout: chain.checkout, settled: settled)
          end
        end

        # The settlement, and the two receipts that name its mandates (§11.3).
        # `settled`: `psp_reference`, `settled_amount_cents` and `network_confirmation_id`.
        def settlement_result(chain, settlement_id, settled, currency)
          psp_reference = settled[:psp_reference]
          receipts = Receipts.issue(checkout: chain.checkout, payment: chain.payment, settlement_id:, psp_reference:,
                                    network_confirmation_id: settled[:network_confirmation_id])
          Result.new(kind: :value, payload: { settlement_id:, psp_reference:, settled_amount_cents: settled[:settled_amount_cents],
                                              currency:, **receipts })
        end
      end

      # The mandate and settlement rows. Every value is a bind parameter; only the
      # operator-set schema name is interpolated.
      module Ledger
        # The byte-identical pair of the acting principal, with its settlement if any.
        CHAIN_SQL = <<~SQL.squish
          SELECT c.id AS checkout_row, c.declined_at,
                 s.id AS settlement_id, s.psp_reference, s.settled_amount_cents, s.currency,
                 s.network_confirmation_id
          FROM %<schema>s.checkout_mandates c
          JOIN %<schema>s.payment_mandates p ON p.checkout_mandate_id = c.id
          LEFT JOIN %<schema>s.settlements s ON s.checkout_mandate_id = c.id
          WHERE c.user_id = $1 AND p.user_id = $1
            AND c.reference = $2
            AND c.sd_jwt = $3
            AND p.sd_jwt = $4
          LIMIT 1
        SQL

        # `line_items` arrives as JSON text; the cast stores a jsonb array rather than a string.
        CHECKOUT_INSERT_SQL = <<~SQL.squish
          INSERT INTO %<schema>s.checkout_mandates
            (reference, checkout_hash, user_id, agent_id, issuer, line_items,
             total_amount_cents, currency, expires_at, created_at, sd_jwt)
          VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, now(), $10)
          RETURNING id
        SQL

        PAYMENT_INSERT_SQL = <<~SQL.squish
          INSERT INTO %<schema>s.payment_mandates
            (reference, checkout_mandate_id, user_id, agent_id, issuer,
             payment_instrument, amount_cents, currency, expires_at, created_at, sd_jwt)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)
          RETURNING id
        SQL

        # Nobody signs a settlement; `UNIQUE (checkout_mandate_id)` keeps it single.
        SETTLEMENT_INSERT_SQL = <<~SQL.squish
          INSERT INTO %<schema>s.settlements
            (checkout_mandate_id, user_id, agent_id, issuer, psp_reference,
             settled_amount_cents, currency, network_confirmation_id, settled_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
          RETURNING id
        SQL

        DECLINE_SQL = <<~SQL.squish
          UPDATE %<schema>s.checkout_mandates SET declined_at = now() WHERE id = $1 AND declined_at IS NULL
        SQL

        private

        def chain_record(chain)
          connection.exec_query(ledger_sql(CHAIN_SQL), 'Kiosk chain lookup', [
                                  identity.user_id, chain.checkout.reference, chain.checkout.sd_jwt, chain.payment.sd_jwt
                                ]).to_a.first
        end

        def decline_checkout(checkout_row)
          connection.exec_query(ledger_sql(DECLINE_SQL), 'Kiosk checkout decline', [checkout_row])
        end

        def persist_checkout_mandate(checkout)
          insert_returning_id('Kiosk checkout_mandate insert', CHECKOUT_INSERT_SQL, [
                                checkout.reference, checkout.checkout_hash, checkout.user_id, checkout.agent_id,
                                checkout.issuer, checkout.line_items.to_json, checkout.total_amount_cents,
                                checkout.currency, checkout.expires_at, checkout.sd_jwt
                              ])
        end

        def persist_payment_mandate(checkout_row_id:, payment:)
          insert_returning_id('Kiosk payment_mandate insert', PAYMENT_INSERT_SQL, [
                                payment.reference, checkout_row_id, payment.user_id, payment.agent_id, payment.issuer,
                                payment.payment_instrument, payment.amount_cents, payment.currency, payment.expires_at,
                                payment.sd_jwt
                              ])
        end

        def persist_settlement(checkout_row_id:, checkout:, settled:)
          insert_returning_id('Kiosk settlement insert', SETTLEMENT_INSERT_SQL, [
                                checkout_row_id, checkout.user_id, checkout.agent_id, checkout.issuer,
                                settled[:psp_reference], settled[:settled_amount_cents].to_i, checkout.currency,
                                settled[:network_confirmation_id]
                              ])
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
      include Repeat
      include SpendingCap
      include Ledger
    end
  end
end
