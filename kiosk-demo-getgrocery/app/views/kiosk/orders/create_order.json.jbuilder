json.order_id @order.id
json.total_cents @order.total_cents
json.total_eur Product.format_eur(@order.total_cents)
json.currency 'eur'
json.slot_at @order.slot_at.in_time_zone(@order.zone).iso8601
json.slot_label DeliverySlots.label(@order.slot_at, @order.zone)
json.timezone @order.timezone
json.pay_hint 'Call `pay` in EUR with a cart mandate (a signed cart) for exactly this order. ' \
              "Its line_items: one {\"order_id\": \"#{@order.id}\"} entry, then one " \
              '{"sku", "qty", "price_cents"} entry per item at catalog prices. ' \
              'The shop checks the currency, prices and total before it charges.'
