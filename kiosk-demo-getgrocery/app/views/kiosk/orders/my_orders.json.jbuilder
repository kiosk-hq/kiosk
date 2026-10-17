json.array! @orders do |order|
  json.order_id order.id
  json.extract! order, :status, :total_cents
  json.slot_at order.slot_at.in_time_zone(order.zone).iso8601
  json.slot_label DeliverySlots.label(order.slot_at, order.zone)
  json.extract! order, :address, :payment_state
end
