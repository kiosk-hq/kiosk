# frozen_string_literal: true

# Places one order for the customer: the basket, its delivery window and
# address, priced at catalogue prices. Returns the order; raises a wire error on a refusal.
class CreateOrderOperation
  def self.call(customer_id:, items:, slot_at:, delivery_address:)
    zone     = DeliverySlots.zone_at(delivery_address)
    products = Product.where(sku: items.pluck(:sku)).index_by(&:sku)
    order    = Order.new(
      user_id: customer_id,
      slot_at: slot_at,
      address: delivery_address,
      timezone: zone.name,
      order_items: items.map { OrderItem.new(sku: it[:sku], product: products[it[:sku]], qty: it[:qty]) }
    )
    order.validate!(:place)

    Kiosk::Server::Kyc.require! if order.order_items.any? { it.product.age_restricted? }

    order.update!(total_cents: order.order_items.sum { it.product.price_cents * it.qty })
    order
  end
end
