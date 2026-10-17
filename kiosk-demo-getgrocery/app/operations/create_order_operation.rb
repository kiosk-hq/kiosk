# frozen_string_literal: true

# Places one order for the customer: the basket, its delivery window and
# address, priced at catalogue prices. Returns the order; raises a wire error on a refusal.
class CreateOrderOperation
  def self.call(customer_id:, items:, slot_at:, delivery_address:)
    order = Order.new(user_id: customer_id, slot_at: slot_at, address: delivery_address,
                      timezone: DeliverySlots.zone_at(delivery_address).name, order_items: lines(items))
    order.validate!(:place)

    Kiosk::Server::Kyc.require! if age_restricted?(order)

    order.update!(total_cents: order.order_items.sum { it.product.price_cents * it.qty })
    order
  end

  def self.age_restricted?(order) = order.order_items.any? { it.product.age_restricted? }

  # One order line per requested item, each with its catalogue product.
  def self.lines(items)
    products = Product.where(sku: items.pluck(:sku)).index_by(&:sku)
    items.map { OrderItem.new(sku: it[:sku], product: products[it[:sku]], qty: it[:qty]) }
  end
end
