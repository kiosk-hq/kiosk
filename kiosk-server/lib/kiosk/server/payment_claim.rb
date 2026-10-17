# frozen_string_literal: true

require 'kiosk/uuid_check'

module Kiosk
  module Server
    # §11.6 over a PSP adapter: claims the operator's payable row `unpaid →
    # paying` before the capture, checks the cart against the operator's price,
    # and flips the row to `paid` once the capture returns.
    class PaymentClaim
      PAYING = 'paying'
      PAID   = 'paid'

      # @param table [String] the payable table, with `id uuid` and `updated_at`
      # @param reference [String] the cart line-item key naming the row, e.g. "order_id"
      # @param query [String] the per-user query that publishes the row's payment state
      def initialize(psp, currency:, table:, reference:, query:, status_column: 'payment_status', # rubocop:disable Metrics/ParameterLists -- the public constructor the operator initializers call
                     unpaid: 'unpaid', owner_column: 'user_id')
        @psp       = psp
        @currency  = currency.to_s.downcase
        @reference = reference
        @query     = query
        @unpaid    = unpaid
        @row       = Row.new(table:, status_column:, owner_column:)
        @options   = { currency:, table:, reference:, query:, status_column:, unpaid:, owner_column: }
        return unless psp.respond_to?(:setup_return_user_id)

        define_singleton_method(:setup_return_user_id) { |params| @psp.setup_return_user_id(params) }
      end

      # The same claim over another PSP adapter.
      def over(psp) = self.class.new(psp, **@options)

      def capture(cart_mandate, payment_method: nil)
        id = claim!(cart_mandate)
        settled = charge(id, cart_mandate, payment_method)
        mark_paid!(id)
        settled
      end

      def setup_required?(user_id:) = @psp.setup_required?(user_id: user_id)

      def setup_url(user_id:, return_url:) = @psp.setup_url(user_id: user_id, return_url: return_url)

      def refund(psp_reference:, amount_cents:) = @psp.refund(psp_reference: psp_reference, amount_cents: amount_cents)

      # True iff the engine holds a settlement whose cart names this row.
      def settled?(id)
        Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(@reference => id)).exists?
      end

      # `paying → paid`, then `c.after_payment`, once: only the call that moved
      # the row runs the hook. A failure here never surfaces: the charge has
      # happened and the settlement row records it.
      def mark_paid!(id)
        return unless @row.flip(id, from: PAYING, to: PAID).positive?

        Kiosk.configuration.after_payment&.call(id)
      rescue StandardError => e
        FailureLog.report("#{self.class} could not mark #{id} paid", e)
        nil
      end

      # `paying → unpaid`, for a claim under which no money moved.
      def release!(id) = @row.flip(id, from: PAYING, to: @unpaid)

      private

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
        refuse_unclaimable!(id, cart.user_id.to_s) unless @row.take(id, cart.user_id.to_s, from: @unpaid, to: PAYING).any?
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
             're-read the pay_hint of the action that created it'
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
        deny "#{noun} #{id} has a payment in progress — re-read GET <endpoint>/#{@query}: while its " \
             'payment_state is `pending` the charge may already have gone through, so do NOT sign a ' \
             'fresh mandate chain; only a `paid` or `unpaid` answer is actionable'
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

      # The operator's payable table: its status column moves under a compare-and-set.
      class Row
        def initialize(table:, status_column:, owner_column:)
          @table         = table
          @status_column = status_column
          @owner_column  = owner_column
        end

        # The ids moved `from → to` for this payer; empty when the row was not in `from`.
        def take(id, payer, from:, to:)
          connection.exec_query(
            "UPDATE #{table} SET #{status_column} = $1, updated_at = now() " \
            "WHERE id = $2::uuid AND #{status_column} = $3 AND #{owner_column} = $4::uuid " \
            'RETURNING id',
            'Kiosk payment claim', [to, id, from, payer]
          ).rows
        end

        def status(id, payer)
          connection.exec_query(
            "SELECT #{status_column} FROM #{table} WHERE id = $1::uuid AND #{owner_column} = $2::uuid",
            'Kiosk payment claim', [id, payer]
          ).rows.first&.first
        end

        def flip(id, from:, to:)
          connection.exec_update(
            "UPDATE #{table} SET #{status_column} = $1, updated_at = now() " \
            "WHERE id = $2::uuid AND #{status_column} = $3",
            'Kiosk payment claim', [to, id.to_s, from]
          )
        end

        private

        def table = connection.quote_table_name(@table)

        def status_column = connection.quote_column_name(@status_column)

        def owner_column = connection.quote_column_name(@owner_column)

        def connection = ::ActiveRecord::Base.lease_connection
      end
    end
  end
end
