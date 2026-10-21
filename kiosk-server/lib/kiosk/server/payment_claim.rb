# frozen_string_literal: true

module Kiosk
  module Server
    # §11.6 over a PSP adapter: claims the operator's payable row `unpaid →
    # paying` before the capture, checks the checkout against the operator's price,
    # flips the row to `paid` once the capture returns, tells its owner on the
    # `payment` topic, and runs `c.after_payment` once the settlement is recorded.
    # A refund through it is recorded against the settlement.
    class PaymentClaim
      UNPAID = 'unpaid'
      PAYING = 'paying'
      PAID   = 'paid'
      TOPIC  = 'payment'
      EXAMPLE_ID = '5f0c2a8e-3b1d-4c6f-9a7e-2d8b4e1f6c03'

      attr_reader :currency, :reference

      # @param model [String] the payable model's name, e.g. "Order"; it includes Kiosk::Owned and Kiosk::Payable
      # @param reference [String] the checkout line-item key naming the row, e.g. "order_id"
      # @param query [String] the per-user query that publishes the row's payment state
      def initialize(psp, currency:, model:, reference:, query:)
        @psp       = psp
        @currency  = currency.to_s.downcase
        @reference = reference
        @query     = query
        @row       = Row.new(model)
        @options   = { currency:, model:, reference:, query: }
        extend SetupReturn if psp.respond_to?(:setup_return_user_id)
      end

      # The same claim over another PSP adapter.
      def over(psp) = self.class.new(psp, **@options)

      def capture(checkout_mandate, payment_method: nil) = charge_row(claim!(checkout_mandate), checkout_mandate, payment_method)

      delegate :setup_required?, :setup_url, to: :@psp

      # The settlements whose checkout names this row.
      def settlements(id) = Kiosk::Settlement.joins(:checkout_mandate).merge(Kiosk::CheckoutMandate.referencing(@reference => id))

      def settled?(id) = settlements(id).exists?

      # `paying → paid`, then the `payment` event, once: only the call that
      # moved the row announces it. A failure here never surfaces: the charge
      # has happened and the settlement row records it.
      def mark_paid!(id)
        announce(id, PAID) if @row.flip(id, from: PAYING, to: PAID).positive?
      rescue StandardError => e
        FailureLog.report("#{self.class} could not mark #{id} paid", e)
        nil
      end

      # `paying → unpaid`, for a claim under which no money moved.
      def release!(id) = @row.flip(id, from: PAYING, to: UNPAID)

      private

      def charge_row(id, checkout_mandate, payment_method)
        settled = charge(id, checkout_mandate, payment_method)
        mark_paid!(id)
        settled
      end

      # Releases the claim when the PSP refuses before any money moved.
      def charge(id, checkout_mandate, payment_method)
        @psp.capture(checkout_mandate, payment_method: payment_method)
      rescue Kiosk::PaymentProviders::SetupRequired
        release!(id)
        raise
      rescue Kiosk::PaymentProviders::PaymentFailed => e
        release!(id) if e.retryable?
        raise
      end

      def claim!(checkout)
        id = Lines.reference(checkout.line_items, @reference)
        refuse_unclaimable!(id, checkout.user_id.to_s) unless @row.take(id, checkout.user_id.to_s, from: UNPAID, to: PAYING).positive?
        begin
          check_price!(checkout, id)
        rescue StandardError
          release!(id)
          raise
        end
        id
      end

      # The price may have moved since the checkout was signed.
      def check_price!(checkout, id)
        total = checkout.total_amount_cents
        price = checker.call(id, checkout.line_items.reject { |li| li[@reference] })
        deny price if price.is_a?(String)
        return if total == price

        deny "checkout total #{total} does not equal this operator's price #{price} for #{noun} #{id}: " \
             'the price changed after the operator signed the checkout'
      end

      def checker
        Kiosk.configuration.checkout_price_checker or
          raise Errors::ConfigurationError, "PaymentClaim needs c.checkout_price_checker, the operator's price"
      end

      def refuse_unclaimable!(id, payer)
        status = @row.status(id, payer)
        deny "#{noun} not found or not yours" if status.nil?
        refuse_paying!(id) if status == PAYING
        deny "#{noun} #{id} is already paid (#{status}) — do not pay it again"
      end

      def refuse_paying!(id)
        if settled?(id)
          mark_paid!(id)
          deny "#{noun} #{id} is already paid"
        end
        deny "#{noun} #{id} has a payment in progress under other mandates. Send those mandates again, " \
             'byte for byte: they cannot charge twice. Do not sign new mandates. ' \
             "GET <endpoint>/#{@query} shows the payment state."
      end

      def noun = @reference.delete_suffix('_id')

      def deny(message)
        raise Errors::Forbidden, message
      end

      # The checkout's line items: the one row they name.
      module Lines
        module_function

        def reference(line_items, key)
          refs = line_items.filter_map { |li| li[key] }.uniq
          return refs.first.to_s if refs.one?

          raise Errors::Forbidden, "checkout line_items must name exactly one #{key}"
        end
      end

      # A repeat of mandates whose capture did not complete. The row stays with
      # the newest unfinished checkout mandate, and the PSP keys the capture by
      # its reference, so the repeat cannot charge twice.
      module Resume
        def resume(checkout_mandate, payment_method: nil) = charge_row(reclaim!(checkout_mandate), checkout_mandate, payment_method)

        private

        # The row these repeated mandates claimed, or the row they may claim now.
        def reclaim!(checkout)
          id = Lines.reference(checkout.line_items, @reference)
          payer = checkout.user_id.to_s
          status = @row.status(id, payer)
          return claim!(checkout) if status == UNPAID
          return id if [PAYING, PAID].include?(status) && !settled?(id) && unfinished_mandate(id, payer) == checkout.reference

          refuse_unclaimable!(id, payer)
        end

        # The reference of the newest checkout mandate for this row that is neither settled nor declined.
        def unfinished_mandate(id, payer)
          Kiosk::CheckoutMandate.referencing(@reference => id).where(user_id: payer, declined_at: nil)
                                .where.missing(:settlements).order(created_at: :desc, id: :desc).pick(:reference)
        end
      end
      include Resume

      # Money the operator gives back, recorded against its settlement.
      module Refund
        # Returns `amount_cents` of the charge `psp_reference` to the card and
        # records the refund against its settlement, so recent spend leaves it
        # out. `key` names this refund among the refunds of the charge: a repeat
        # with the same key is the same refund, and is recorded once. The PSP's receipt.
        def refund(psp_reference:, amount_cents:, key:)
          receipt = @psp.refund(psp_reference:, amount_cents:, key:)
          binds = receipt.values_at(:psp_reference, :refunded_amount_cents, :refunded_at, :refunded_psp_reference)
          ::ActiveRecord::Base.lease_connection.exec_query(format(INSERT_SQL, schema: Kiosk.configuration.schema), 'Kiosk refund', binds)
          receipt
        end

        INSERT_SQL = <<~SQL.squish
          INSERT INTO "%<schema>s".refunds (settlement_id, psp_reference, refunded_amount_cents, refunded_at)
          SELECT id, $1, $2, $3 FROM "%<schema>s".settlements WHERE psp_reference = $4
          ON CONFLICT (psp_reference) DO NOTHING
        SQL
      end
      include Refund

      # The operator's work after a payment, which reads the settlement.
      module AfterPayment
        # The executor calls this once, after it records the settlement of
        # `checkout_mandate`, so `c.after_payment` reads the row's `settlement`. A
        # failure here never surfaces on the wire: the log carries it.
        def settled(checkout_mandate)
          id = Lines.reference(checkout_mandate.line_items, @reference)
          Kiosk.configuration.after_payment&.call(id)
        rescue StandardError => e
          FailureLog.report("#{self.class} after_payment failed for #{id}", e)
          nil
        end
      end
      include AfterPayment

      # The `payment` topic, which the engine serves beside `payment_setup`, and
      # its events: where the money for one row stands.
      module Topic
        # Tells the row's owner where its money stands: `paid` or `refunded`.
        def announce(id, payment_state)
          Events.emit(topic: TOPIC, subject: id, identity_scope: [@row.owner(id)],
                      data: { @reference => id, 'payment_state' => payment_state })
        end

        def topic
          @topic ||= { name: TOPIC, reach: :principal,
                       description: "The money for one #{noun} of yours moved. `paid`: the charge went through. " \
                                    '`refunded`: the charge went back to the card.',
                       payload_schema: { type: 'object', additionalProperties: false,
                                         properties: { @reference => { type: 'string', format: 'uuid' },
                                                       'payment_state' => { enum: [PAID, Kiosk::Payable::REFUNDED] } },
                                         required: [@reference, 'payment_state'] },
                       examples: [PAID, Kiosk::Payable::REFUNDED].map { { @reference => EXAMPLE_ID, 'payment_state' => it } },
                       subject_reachable: ->(id, identity) { !@row.status(id, identity.user_id.to_s).nil? } }.freeze
        end
      end
      include Topic

      # The PSP names whose human came back from the setup page; the engine
      # serves the `payment_setup` topic only for a provider that has this method.
      module SetupReturn
        delegate :setup_return_user_id, to: :@psp
      end

      # The operator's payable rows: the status moves under a compare-and-set.
      class Row
        def initialize(model)
          @model = model
        end

        # Moves this payer's row `from → to`; the count of rows moved, 0 or 1.
        def take(id, payer, from:, to:) = move(model.owned_by(payer).where(id:), from:, to:)

        def status(id, payer) = model.owned_by(payer).where(id:).pick(:payment_status)

        def owner(id) = model.where(id:).pick(:user_id)

        def flip(id, from:, to:) = move(model.where(id:), from:, to:)

        private

        def move(rows, from:, to:)
          # One conditional UPDATE is the atomic compare-and-set: the row count says which caller won.
          rows.where(payment_status: from).update_all({ payment_status: to }.merge(timestamps)) # rubocop:disable Rails/SkipsModelValidations -- a per-row save cannot move a row atomically
        end

        def timestamps
          now = model.current_time_from_proper_timezone
          model.timestamp_attributes_for_update_in_model.index_with { now }
        end

        def model = @model.constantize
      end
    end
  end
end
