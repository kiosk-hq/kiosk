# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  # `include Kiosk::Payable` in the model that `Kiosk::Server::PaymentClaim`
  # names. It gives the row its `payment_state`, the `checkout_jwt` an
  # assistant's mandates bind to pay for it, and the `settlement` that paid it.
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

    # The `checkout_jwt` member of the answer of an action that creates a payable row.
    CHECKOUT_SCHEMA = {
      type: 'string',
      description: 'The checkout to pay, signed by this operator. Put it unchanged in your checkout mandate.'
    }.freeze

    class_methods do
      # Adds `settled_currency`, the currency of a settlement among `settlements`
      # whose checkout names the row, or NULL: the caller's own in the protocol, all
      # of them in a back office.
      def with_settlement(settlements)
        select(arel_table[Arel.star],
               Arel::Nodes::Grouping.new(settlements.joins(:checkout_mandate).where(names_row).select(:currency)
                                                    .limit(1).arel).as('settled_currency'))
      end

      def payment_claim = Kiosk.configuration.payment_provider

      private

      # `checkout_mandates.line_items @> [{"<reference>": "<this row's id>"}]`.
      def names_row
        line = Arel::Nodes::NamedFunction.new(
          'jsonb_build_object', [Arel::Nodes.build_quoted(payment_claim.reference),
                                 Arel::Nodes::NamedFunction.new('CAST', [arel_table[:id].as(Arel.sql('text'))])]
        )
        Arel::Nodes::InfixOperation.new('@>', Kiosk::CheckoutMandate.arel_table[:line_items],
                                        Arel::Nodes::NamedFunction.new('jsonb_build_array', [line]))
      end
    end

    # `pending` means a capture is in flight: the caller reads again and does
    # not sign new mandates. A row read without `with_settlement` asks the
    # settlements itself.
    def payment_state
      status = self[:payment_status]
      return REFUNDED if status == REFUNDED
      return PAID     if status == PAID || settled?
      return PENDING  if status == Kiosk::Server::PaymentClaim::PAYING

      UNPAID
    end

    # The signed checkout that pays for this row, for its owner: a line naming
    # the row, then `lines`, each `{qty:, price_cents:, ...}`, which sum to the total.
    def checkout(lines)
      claim = self.class.payment_claim
      Kiosk::Server::Checkout.sign(user_id: user_id, currency: claim.currency,
                                   total_amount_cents: lines.sum { it[:qty] * it[:price_cents] },
                                   line_items: [{ claim.reference => id }, *lines])
    end

    # The first settlement whose checkout names this row, or nil.
    def settlement = self.class.payment_claim.settlements(id).order(:created_at).first

    private

    def settled? = has_attribute?(:settled_currency) ? !settled_currency.nil? : !settlement.nil?
  end
end
