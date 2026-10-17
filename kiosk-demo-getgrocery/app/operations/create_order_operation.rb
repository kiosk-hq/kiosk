# frozen_string_literal: true

# Places one order for the customer: the basket, its delivery window and
# address, each line at today's catalogue price. Returns the order; raises a wire error on a refusal.
class CreateOrderOperation
  def self.call(customer_id:, items:, slot_at:, delivery_address:)
    order = Order.new(user_id: customer_id, slot_at: slot_at, address: delivery_address,
                      timezone: DeliverySlots.zone_at(delivery_address).name, order_items: lines(items))
    order.validate!(:place)

    refuse_short!(order)
    Kiosk::Server::Kyc.require! if age_restricted?(order)

    order.update!(total_cents: order.order_items.sum { it.price_cents * it.qty })
    order
  end

  def self.refuse_short!(order)
    short = order.shortfall
    return if short.empty?

    raise Kiosk::Server::Errors::Conflict.new("not enough in stock — #{short.join('; ')}",
                                              hint: 'Call catalog for what is in stock, then order again.')
  end

  def self.age_restricted?(order) = order.order_items.any? { it.product.age_restricted? }

  # One order line per requested item, each with its catalogue product and price.
  def self.lines(items)
    products = Product.where(sku: items.pluck(:sku)).index_by(&:sku)
    items.map do |item|
      product = products[item[:sku]]
      OrderItem.new(sku: item[:sku], product:, qty: item[:qty], price_cents: product&.price_cents)
    end
  end
end
