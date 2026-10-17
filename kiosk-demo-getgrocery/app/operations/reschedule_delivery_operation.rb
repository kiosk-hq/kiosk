# frozen_string_literal: true

# Moves a paid order to another delivery window, and optionally another
# address, on the payment it already has. Returns the order; raises a wire error on a refusal.
class RescheduleDeliveryOperation
  def self.call(order_id:, slot_at:, delivery_address:)
    order = Order.own.reschedulable.find_by(id: order_id)
    # One answer for absent, foreign and already moved, so ids cannot be probed.
    refuse 'no order of yours with this id can be moved: it was moved once already or is with the courier' unless order
    refuse "this order's payment is still in progress; reschedule once my_orders reads `paid`" if order.paying?
    refuse 'this order is not paid; only a paid order can be moved' unless order.paid?

    address = delivery_address.presence || order.address
    zone    = DeliverySlots.zone_at(address)
    order.assign_attributes(status: :rescheduled, address: address, timezone: zone.name, slot_at: slot_at)
    order.save!(context: :reschedule)
    CourierDispatchJob.arm!(order.id)
    order
  end

  def self.refuse(message)
    raise Kiosk::Server::Errors::Forbidden, message
  end
end
