# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  # `include Kiosk::Payable` in the model that `Kiosk::Server::PaymentClaim`
  # names. It gives the row its `payment_state`, the `cart` an assistant signs
  # to pay for it, and the `settlement` that paid it.
  module Payable
    extend ActiveSupport::Concern

    UNPAID   = 'unpaid'
    PENDING  = 'pending'
    PAID     = 'paid'
    REFUNDED = 'refunded'

    # The `payment_state` member of a per-user query's row.
    STATE_SCHEMA = {
      type: 'string', enum: [UNPAID, PENDING, PAID, REFUNDED],
      description: '`unpaid`: nothing is charged; pay for it. `pending`: a charge is in progress and can ' \
                   'already have taken the money; read again, do not pay again. `paid`: charged. ' \
                   '`refunded`: the charge went back to the card.'
    }.freeze

    # The `cart` member of the answer of an action that creates a payable row.
    CART_SCHEMA = {
      type: 'object', additionalProperties: false,
      description: 'Sign the cart mandate with these three values, unchanged.',
      properties: {
        currency: { type: 'string' },
        total_amount_cents: { type: 'integer' },
        line_items: { type: 'array', items: { type: 'object' } }
      },
      required: %w[currency total_amount_cents line_items]
    }.freeze

    class_methods do
      # Adds `settled_currency`, the currency of a settlement among `settlements`
      # whose cart names the row, or NULL: the caller's own on the wire, all of
      # them in a back office.
      def with_settlement(settlements)
        select(arel_table[Arel.star],
               Arel::Nodes::Grouping.new(settlements.joins(:cart_mandate).where(names_row).select(:currency)
                                                    .limit(1).arel).as('settled_currency'))
      end

      def payment_claim = Kiosk.configuration.payment_provider

      private

      # `cart_mandates.line_items @> [{"<reference>": "<this row's id>"}]`.
      def names_row
        line = Arel::Nodes::NamedFunction.new(
          'jsonb_build_object', [Arel::Nodes.build_quoted(payment_claim.reference),
                                 Arel::Nodes::NamedFunction.new('CAST', [arel_table[:id].as(Arel.sql('text'))])]
        )
        Arel::Nodes::InfixOperation.new('@>', Kiosk::CartMandate.arel_table[:line_items],
                                        Arel::Nodes::NamedFunction.new('jsonb_build_array', [line]))
      end
    end

    # `pending` means a capture is in flight: the caller reads again and does
    # not sign a new mandate. A row read without `with_settlement` asks the
    # settlements itself.
    def payment_state
      status = self[self.class.payment_claim.status_column]
      return REFUNDED if status == REFUNDED
      return PAID     if status == PAID || settled?
      return PENDING  if status == Kiosk::Server::PaymentClaim::PAYING

      UNPAID
    end

    # The cart that pays for this row: a line naming the row, then `lines`,
    # each `{qty:, price_cents:, ...}`, which sum to the total.
    def cart(lines)
      claim = self.class.payment_claim
      { currency: claim.currency,
        total_amount_cents: lines.sum { it[:qty] * it[:price_cents] },
        line_items: [{ claim.reference => id }, *lines] }
    end

    # The first settlement whose cart names this row, or nil.
    def settlement = self.class.payment_claim.settlements(id).order(:created_at).first

    private

    def settled? = has_attribute?(:settled_currency) ? !settled_currency.nil? : !settlement.nil?
  end
end
