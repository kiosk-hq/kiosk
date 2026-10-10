# frozen_string_literal: true

# Moves a paid order to another delivery window, and optionally another
# address, on the payment it already has. Raises a wire error on a refusal.
class RescheduleDeliveryOperation
  def self.call(order_id:, delivery_slot_id:, delivery_date:, delivery_address:)
    order = Order.own.reschedulable.find_by(id: order_id)
    # One answer for absent, foreign and already moved, so ids cannot be probed.
    refuse "order not found, not yours, already rescheduled (one reschedule per order), " \
           "or already with the courier" unless order
    refuse "a payment for this order is in progress and its outcome is not yet known — re-read " \
           "my_orders and reschedule once its payment_state is `paid`; do NOT sign a fresh " \
           "mandate chain while it reads `pending`" if order.paying?
    refuse "this order is not paid yet — reschedule_delivery moves an already-paid order on its " \
           "existing payment. Pay for it first, or place the order you want with create_order " \
           "and leave this one unpaid" unless order.paid?

    address = delivery_address.presence || order.address
    zone    = DeliverySlots.zone_at(address)
    order.assign_attributes(status: :rescheduled, address: address, timezone: zone.name,
                            slot_at: DeliverySlots.slot_at(Date.iso8601(delivery_date), delivery_slot_id, zone))
    order.save!(context: :reschedule)
    CourierDispatchJob.arm!(order.id)

    { order_id:          order.id,
      rescheduled_at:    order.slot_at.in_time_zone(zone).iso8601,
      rescheduled_label: DeliverySlots.label(order.slot_at, zone),
      timezone:          zone.name }
  end

  def self.refuse(message)
    raise Kiosk::Server::Errors::Forbidden, message
  end
end
