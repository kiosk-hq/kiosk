# frozen_string_literal: true

json.order_id @order.id
json.total_cents @order.total_cents
json.total_eur Product.format_eur(@order.total_cents)
json.currency 'eur'
json.slot_at @order.slot_at.in_time_zone(@order.zone).iso8601
json.slot_label DeliverySlots.label(@order.slot_at, @order.zone)
json.timezone @order.timezone
json.cart @order.cart(@order.order_items.map { { sku: it.product.sku, qty: it.qty, price_cents: it.price_cents } })
