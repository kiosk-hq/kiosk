# frozen_string_literal: true

# Places one order for the principal: the basket, its delivery window and
# address, priced at catalogue prices. Raises a wire error on a refusal.
class CreateOrderOperation
  def self.call(principal_id:, items:, delivery_slot_id:, delivery_date:, delivery_address:)
    zone    = DeliverySlots.zone_for(WireArguments.served_district(delivery_address))
    date    = WireArguments.delivery_date(delivery_date, zone: zone)
    WireArguments.bookable_slot!(date, delivery_slot_id, zone)
    slot_at = DeliverySlots.slot_at(date, delivery_slot_id, zone)

    products = Product.where(sku: items.map { _1[:sku] }).index_by(&:sku)
    unknown  = items.map { _1[:sku] }.uniq - products.keys
    WireArguments.refuse("unknown sku(s): #{unknown.join(", ")}") if unknown.any?

    Kiosk::Server::Kyc.require! if items.any? { products[_1[:sku]].age_restricted? }

    total_cents = items.sum { products[_1[:sku]].price_cents * _1[:qty].to_i }
    WireArguments.priceable_total!(total_cents)

    order = Order.create!(
      user_id:     principal_id,
      total_cents: total_cents,
      slot_at:     slot_at,
      address:     delivery_address,
      timezone:    zone.name,
      order_items: items.map { OrderItem.new(product: products[_1[:sku]], qty: _1[:qty].to_i) },
    )

    {
      order_id:    order.id,
      total_cents: total_cents,
      total_eur:   Product.format_eur(total_cents),
      currency:    "eur",
      slot_at:     slot_at.iso8601,
      slot_label:  DeliverySlots.label(slot_at, zone),
      timezone:    zone.name,
      pay_hint:    "pay in EUR with a cart mandate whose line_items mirror this order: " \
                   "one {\"order_id\": \"#{order.id}\"} entry plus one " \
                   "{\"sku\", \"qty\", \"price_cents\"} entry per item at catalog prices — " \
                   "the operator verifies currency, prices, and total before charging",
    }
  end
end
