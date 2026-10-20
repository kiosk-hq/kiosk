# frozen_string_literal: true

# Once per paid order, whoever reports the payment first: the basket leaves
# the shelf and the courier is booked. `dispatch_at` is NULL until then. The
# price of a line that a concurrent payment emptied the shelf of goes back to
# the card. When the payment processor refuses that refund, the price is
# credit on the shopper's account and the shop's error reporter gets the
# error. An order with no line left is cancelled.
class FulfilOrderOperation
  def self.call(order_id)
    Order.transaction do
      order = Order.paid.where(dispatch_at: nil).lock.find_by(id: order_id)
      next unless order

      missing = take_off_shelf(order)
      give_back(order, missing.sum { it.price_cents * it.qty }) if missing.any?
      CourierDispatchJob.arm!(order) unless order.cancelled?
    end
  end

  # The lines the shelf could not fill.
  def self.take_off_shelf(order)
    order.order_items.sort_by(&:product_id).reject { Product.take!(it.product_id, it.qty) }
  end

  def self.give_back(order, amount)
    if refund(order, amount)
      order.refunded_cents = amount
    else
      order.credited_cents = amount
    end
    order.status = :cancelled if amount == order.total_cents
    order.payment_status = :refunded if order.cancelled? && order.refunded_cents.positive?
    order.save!
    tell(order)
  end

  # True when the card got `amount` back.
  def self.refund(order, amount)
    payment_provider.refund(psp_reference: order.settlement.psp_reference, amount_cents: amount, key: order.id)
    true
  rescue Kiosk::PaymentProviders::PaymentFailed => e
    Rails.logger.error("Order #{order.id}: the refund of #{amount} cents failed (#{e.message}); it is credit on the account")
    Rails.error.report(e, severity: :error, context: { order_id: order.id, credited_cents: amount })
    false
  end

  # The assistant hears of a cancelled order and of new credit on `order_delivery`,
  # and of a full refund on `payment`.
  def self.tell(order)
    if order.cancelled? || order.credited_cents.positive?
      data = { 'order_id' => order.id, 'status' => order.status, 'credited_cents' => order.credited_cents.nonzero? }
      Kiosk::Server::Events.emit(topic: :order_delivery, subject: order.id, identity_scope: [order.user_id],
                                 data: data.compact)
    end
    payment_provider.announce(order.id, Kiosk::Payable::REFUNDED) if order.refunded?
  end

  def self.payment_provider = Kiosk.configuration.payment_provider
end
