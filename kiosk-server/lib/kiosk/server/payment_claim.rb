# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/failure_log"
require "kiosk/uuid_check"

module Kiosk
  module Server
    # The operator half of §11.6, as a decorator over the PSP adapter.
    #
    # Before the capture it claims the operator's own payable row, `unpaid →
    # paying`, with one conditional UPDATE: a second `pay` for that row, on any
    # mandate chain, matches nothing and is refused before the processor is
    # reached. When the capture returns it flips the row to `paid`, so the paid
    # state the operator publishes rests on the capture and not on the
    # settlement row the engine writes after it. A definitive decline releases
    # the claim; an unknown outcome keeps it, so the row reads *pending* until
    # it is resolved.
    #
    # Under the claim it checks the signed cart: the operator's currency, priced
    # lines that sum to the total, and a total equal to the operator's own price
    # for the row, which `c.cart_price_checker` answers from its catalog:
    #
    #   c.payment_provider = Kiosk::Server::PaymentClaim.new(
    #     psp, currency: "eur", table: "bookings", reference: "booking_id",
    #          query: "my_bookings",
    #   )
    #   c.cart_price_checker = PriceChecker            # call(booking_id, lines) → cents | refusal
    #   c.after_payment      = ->(id) { Booking.paid!(id) }   # optional
    class PaymentClaim
      PAYING = "paying"
      PAID   = "paid"

      # @param psp the PSP adapter that captures
      # @param currency [String] the one currency this operator prices in
      # @param table [String] the operator's payable table, which has `id uuid`
      #   and `updated_at`
      # @param reference [String] the cart line-item key naming the row, e.g. "order_id"
      # @param query [String] the per-user query that publishes the row's payment state
      # @param status_column [String]
      # @param unpaid [String] the status a payable row waits in
      # @param owner_column [String] the row's owner; a principal pays only for its own rows
      def initialize(psp, currency:, table:, reference:, query:, status_column: "payment_status",
                     unpaid: "unpaid", owner_column: "user_id")
        @psp           = psp
        @currency      = currency.to_s.downcase
        @table         = table
        @reference     = reference
        @query         = query
        @status_column = status_column
        @unpaid        = unpaid
        @owner_column  = owner_column
        @options       = { currency:, table:, reference:, query:, status_column:, unpaid:, owner_column: }
        return unless psp.respond_to?(:setup_return_user_id)

        define_singleton_method(:setup_return_user_id) { |params| @psp.setup_return_user_id(params) }
      end

      # The same claim over another PSP adapter.
      def over(psp) = self.class.new(psp, **@options)

      def capture(cart_mandate, payment_method: nil)
        id = claim!(cart_mandate)
        begin
          settled = @psp.capture(cart_mandate, payment_method: payment_method)
        rescue Kiosk::PaymentProviders::SetupRequired
          release!(id)
          raise
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          release!(id) if e.retryable?
          raise
        end
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

      # `paying → paid`, then `c.after_payment`. A failure here never surfaces:
      # the charge has happened and the settlement row records it.
      def mark_paid!(id)
        flip(id, to: PAID)
        Kiosk.configuration.after_payment&.call(id)
      rescue StandardError => e
        FailureLog.report("#{self.class} could not mark #{id} paid", e)
        nil
      end

      # `paying → unpaid`, for a claim under which no money moved.
      def release!(id) = flip(id, to: @unpaid)

      private

      def claim!(cart)
        unless cart.currency.to_s.downcase == @currency
          deny "cart currency #{cart.currency.inspect} rejected — this operator prices in #{@currency.upcase}"
        end
        refs = Array(cart.line_items).filter_map { |li| li[@reference] }.map(&:to_s).uniq
        deny "cart line_items must reference exactly one #{@reference}" unless refs.size == 1
        id = refs.first
        unless Kiosk::UuidCheck.valid?(id)
          raise Errors::BadRequest.new("cart line_items #{@reference} #{id.inspect} is not a uuid",
                                       hint: "use the `#{@reference}` this operator returned, verbatim")
        end

        refuse_unclaimable!(id, cart.user_id.to_s) unless take(id, cart.user_id.to_s)
        begin
          check_price!(cart, id)
        rescue StandardError
          release!(id)
          raise
        end
        id
      end

      def check_price!(cart, id)
        total = cart.total_amount_cents.to_i
        lines = Array(cart.line_items).reject { |li| li[@reference] }
        priced = lines.select { |li| li["price_cents"] }
        unless priced.empty?
          sum = priced.sum do |li|
            qty = li["qty"].to_i
            price = li["price_cents"].to_i
            deny "each priced line needs a positive qty and price_cents" if qty <= 0 || price <= 0
            qty * price
          end
          deny "cart total #{total} does not equal the sum of its line items #{sum}" unless total == sum
        end

        price = checker.call(id, lines)
        deny price if price.is_a?(String)
        return if total == price

        deny "cart total #{total} does not equal this operator's price #{price} for #{noun} #{id} — " \
             "re-read the pay_hint of the action that created it"
      end

      def checker
        Kiosk.configuration.cart_price_checker or
          raise Errors::ConfigurationError, "PaymentClaim needs c.cart_price_checker, the operator's price"
      end

      def take(id, payer)
        connection.exec_query(
          "UPDATE #{table} SET #{column(@status_column)} = $1, updated_at = now() " \
          "WHERE id = $2::uuid AND #{column(@status_column)} = $3 AND #{column(@owner_column)} = $4::uuid " \
          "RETURNING id",
          "Kiosk payment claim", [PAYING, id, @unpaid, payer]
        ).rows.any?
      end

      def refuse_unclaimable!(id, payer)
        status = connection.exec_query(
          "SELECT #{column(@status_column)} FROM #{table} WHERE id = $1::uuid AND #{column(@owner_column)} = $2::uuid",
          "Kiosk payment claim", [id, payer]
        ).rows.first&.first

        deny "#{noun} not found or not yours" if status.nil?
        if status == PAYING && settled?(id)
          mark_paid!(id)
          deny "#{noun} #{id} is already paid"
        end
        if status == PAYING
          deny "#{noun} #{id} has a payment in progress — re-read GET <endpoint>/#{@query}: while its " \
               "payment_state is `pending` the charge may already have gone through, so do NOT sign a " \
               "fresh mandate chain; only a `paid` or `unpaid` answer is actionable"
        end
        deny "#{noun} #{id} is already paid (#{status}) — do not pay it again"
      end

      def flip(id, to:)
        connection.exec_update(
          "UPDATE #{table} SET #{column(@status_column)} = $1, updated_at = now() " \
          "WHERE id = $2::uuid AND #{column(@status_column)} = $3",
          "Kiosk payment claim", [to, id.to_s, PAYING]
        )
      end

      def noun = @reference.delete_suffix("_id")

      def table = connection.quote_table_name(@table)

      def column(name) = connection.quote_column_name(name)

      def connection = ::ActiveRecord::Base.lease_connection

      def deny(message)
        raise Errors::Forbidden, message
      end
    end
  end
end
