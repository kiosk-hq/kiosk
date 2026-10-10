# frozen_string_literal: true

# Places one order for the principal: the basket, its delivery window and
# address, priced at catalogue prices. Raises a wire error on a refusal.
class CreateOrderOperation
  def self.call(principal_id:, items:, delivery_slot_id:, delivery_date:, delivery_address:)
    zone     = DeliverySlots.zone_at(delivery_address)
    products = Product.where(sku: items.pluck(:sku)).index_by(&:sku)
    order    = Order.new(
      user_id:     principal_id,
      slot_at:     DeliverySlots.slot_at(Date.iso8601(delivery_date), delivery_slot_id, zone),
      address:     delivery_address,
      timezone:    zone.name,
      order_items: items.map { OrderItem.new(sku: _1[:sku], product: products[_1[:sku]], qty: _1[:qty]) },
    )
    order.validate!(:place)

    Kiosk::Server::Kyc.require! if order.order_items.any? { _1.product.age_restricted? }

    order.update!(total_cents: order.order_items.sum { _1.product.price_cents * _1.qty })

    {
      order_id:    order.id,
      total_cents: order.total_cents,
      total_eur:   Product.format_eur(order.total_cents),
      currency:    "eur",
      slot_at:     order.slot_at.in_time_zone(zone).iso8601,
      slot_label:  DeliverySlots.label(order.slot_at, zone),
      timezone:    zone.name,
      pay_hint:    "pay in EUR with a cart mandate whose line_items mirror this order: " \
                   "one {\"order_id\": \"#{order.id}\"} entry plus one " \
                   "{\"sku\", \"qty\", \"price_cents\"} entry per item at catalog prices — " \
                   "the operator verifies currency, prices, and total before charging",
    }
  end
end
