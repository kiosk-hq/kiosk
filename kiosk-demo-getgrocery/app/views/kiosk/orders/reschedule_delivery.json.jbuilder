# frozen_string_literal: true
json.order_id @order.id
json.rescheduled_at @order.slot_at.in_time_zone(@order.zone).iso8601
json.rescheduled_label DeliverySlots.label(@order.slot_at, @order.zone)
json.timezone @order.timezone
