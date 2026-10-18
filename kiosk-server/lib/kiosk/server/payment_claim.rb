# frozen_string_literal: true

require 'kiosk/uuid_check'

module Kiosk
  module Server
    # §11.6 over a PSP adapter: claims the operator's payable row `unpaid →
    # paying` before the capture, checks the cart against the operator's price,
    # flips the row to `paid` once the capture returns, tells its owner on the
    # `payment` topic, and runs `c.after_payment` once the settlement is recorded.
    # A refund through it is recorded against the settlement.
    class PaymentClaim
      PAYING = 'paying'
      PAID   = 'paid'
      TOPIC  = 'payment'
      EXAMPLE_ID = '5f0c2a8e-3b1d-4c6f-9a7e-2d8b4e1f6c03'

      attr_reader :currency, :reference, :status_column

      # @param model [String] the payable model's name, e.g. "Order"; it includes Kiosk::Owned and Kiosk::Payable
      # @param reference [String] the cart line-item key naming the row, e.g. "order_id"
      # @param query [String] the per-user query that publishes the row's payment state
      def initialize(psp, currency:, model:, reference:, query:, status_column: :payment_status, unpaid: 'unpaid') # rubocop:disable Metrics/ParameterLists -- the public constructor the operator initializers call
        @psp       = psp
        @currency  = currency.to_s.downcase
        @reference = reference
        @query     = query
        @unpaid    = unpaid
        @status_column = status_column
        @row       = Row.new(model:, status_column:)
        @options   = { currency:, model:, reference:, query:, status_column:, unpaid: }
        extend SetupReturn if psp.respond_to?(:setup_return_user_id)
      end

      # The same claim over another PSP adapter.
      def over(psp) = self.class.new(psp, **@options)

      def capture(cart_mandate, payment_method: nil) = charge_row(claim!(cart_mandate), cart_mandate, payment_method)

      delegate :setup_required?, :setup_url, to: :@psp

      # The settlements whose cart names this row.
      def settlements(id) = Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(@reference => id))

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
      def release!(id) = @row.flip(id, from: PAYING, to: @unpaid)

      private

      def charge_row(id, cart_mandate, payment_method)
        settled = charge(id, cart_mandate, payment_method)
        mark_paid!(id)
        settled
      end

      # Releases the claim when the PSP refuses before any money moved.
      def charge(id, cart_mandate, payment_method)
        @psp.capture(cart_mandate, payment_method: payment_method)
      rescue Kiosk::PaymentProviders::SetupRequired
        release!(id)
        raise
      rescue Kiosk::PaymentProviders::PaymentFailed => e
        release!(id) if e.retryable?
        raise
      end

      def claim!(cart)
        id = referenced_id(cart)
        refuse_unclaimable!(id, cart.user_id.to_s) unless @row.take(id, cart.user_id.to_s, from: @unpaid, to: PAYING).positive?
        begin
          check_price!(cart, id)
        rescue StandardError
          release!(id)
          raise
        end
        id
      end

      # The one row the cart's line items name, in the operator's currency.
      def referenced_id(cart)
        deny "cart currency #{cart.currency.inspect} rejected — this operator prices in #{@currency.upcase}" unless cart.currency.to_s.downcase == @currency
        Lines.reference(cart.line_items, @reference)
      end

      def check_price!(cart, id)
        total = cart.total_amount_cents.to_i
        lines = Array(cart.line_items).reject { |li| li[@reference] }
        Lines.check_sum!(total, lines)

        price = checker.call(id, lines)
        deny price if price.is_a?(String)
        return if total == price

        deny "cart total #{total} does not equal this operator's price #{price} for #{noun} #{id} — " \
             'sign the `cart` that the action which created it returned'
      end

      def checker
        Kiosk.configuration.cart_price_checker or
          raise Errors::ConfigurationError, "PaymentClaim needs c.cart_price_checker, the operator's price"
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
        deny "#{noun} #{id} has a payment in progress under another chain. Send that chain again, " \
             'byte for byte: it cannot charge twice. Do not sign a new chain. ' \
             "GET <endpoint>/#{@query} shows the payment state."
      end

      def noun = @reference.delete_suffix('_id')

      def deny(message)
        raise Errors::Forbidden, message
      end

      # The cart's line items: the one row they name, and the priced lines' sum.
      module Lines
        module_function

        def reference(line_items, key)
          refs = Array(line_items).filter_map { |li| li[key] }.map(&:to_s).uniq
          deny "cart line_items must reference exactly one #{key}" unless refs.size == 1
          id = refs.first
          return id if Kiosk::UuidCheck.valid?(id)

          raise Errors::BadRequest.new("cart line_items #{key} #{id.inspect} is not a uuid",
                                       hint: "use the `#{key}` this operator returned, verbatim")
        end

        # The priced lines, when any, sum to the cart total.
        def check_sum!(total, lines)
          priced = lines.select { |li| li['price_cents'] }
          return if priced.empty?

          sum = priced.sum do |li|
            qty = li['qty'].to_i
            price = li['price_cents'].to_i
            deny 'each priced line needs a positive qty and price_cents' if qty <= 0 || price <= 0
            qty * price
          end
          deny "cart total #{total} does not equal the sum of its line items #{sum}" unless total == sum
        end

        def deny(message)
          raise Errors::Forbidden, message
        end
      end

      # A repeat of a chain whose capture did not complete. The row stays with
      # the newest unfinished chain, and the PSP keys the capture by the cart
      # mandate id, so the repeat cannot charge twice.
      module Resume
        def resume(cart_mandate, payment_method: nil) = charge_row(reclaim!(cart_mandate), cart_mandate, payment_method)

        private

        # The row this repeated chain claimed, or the row it may claim now.
        def reclaim!(cart)
          id = referenced_id(cart)
          payer = cart.user_id.to_s
          status = @row.status(id, payer)
          return claim!(cart) if status == @unpaid
          return id if [PAYING, PAID].include?(status) && !settled?(id) && unfinished_chain(id, payer) == cart.id

          refuse_unclaimable!(id, payer)
        end

        # The signed id of the newest cart for this row that is neither settled nor declined.
        def unfinished_chain(id, payer)
          Kiosk::CartMandate.referencing(@reference => id).where(user_id: payer, declined_at: nil)
                            .where.missing(:settlements).order(created_at: :desc, id: :desc).pick(:mandate_id)
        end
      end
      include Resume

      # Money the operator gives back, recorded against its settlement.
      module Refund
        # Returns `amount_cents` of the charge `psp_reference` to the card and
        # records the refund against its settlement, so recent spend leaves it
        # out. A repeat of one PSP refund records it once. The PSP's receipt.
        def refund(psp_reference:, amount_cents:)
          receipt = @psp.refund(psp_reference:, amount_cents:)
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
        # `cart_mandate`, so `c.after_payment` reads the row's `settlement`. A
        # failure here never surfaces on the wire: the log carries it.
        def settled(cart_mandate)
          id = Lines.reference(cart_mandate.line_items, @reference)
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
        def initialize(model:, status_column:)
          @model         = model
          @status_column = status_column
        end

        # Moves this payer's row `from → to`; the count of rows moved, 0 or 1.
        def take(id, payer, from:, to:) = move(model.owned_by(payer).where(id:), from:, to:)

        def status(id, payer) = model.owned_by(payer).where(id:).pick(@status_column)

        def owner(id) = model.where(id:).pick(:user_id)

        def flip(id, from:, to:) = move(model.where(id:), from:, to:)

        private

        def move(rows, from:, to:)
          # One conditional UPDATE is the atomic compare-and-set: the row count says which caller won.
          rows.where(@status_column => from).update_all({ @status_column => to }.merge(timestamps)) # rubocop:disable Rails/SkipsModelValidations -- a per-row save cannot move a row atomically
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
