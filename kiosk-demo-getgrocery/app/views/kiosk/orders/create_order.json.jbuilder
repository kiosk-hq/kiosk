# frozen_string_literal: true

json.order_id @order.id
json.total_cents @order.total_cents
json.total_eur Product.format_eur(@order.total_cents)
json.currency 'eur'
json.slot_at @order.slot_at.in_time_zone(@order.zone).iso8601
json.slot_label DeliverySlots.label(@order.slot_at, @order.zone)
json.timezone @order.timezone
lines = [{ order_id: @order.id }] +
        @order.order_items.map { { sku: it.product.sku, qty: it.qty, price_cents: it.price_cents } }
json.pay_hint 'Call `pay` in EUR with a cart mandate (a signed cart) for exactly this order, at total_cents. ' \
              "Its line_items: #{lines.to_json}. " \
              'The shop checks the currency, prices, total and stock before it charges.'
