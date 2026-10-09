# frozen_string_literal: true

# The courier leaves once the basket is picked, 20–30 minutes after payment,
# and not before the order's window opens.
class CourierDispatchJob < ApplicationJob
  queue_as :default

  # Called when an order is paid and again when its window moves; a run left
  # over from the old schedule finds the order not yet due and re-enqueues.
  def self.arm!(order_id)
    order = Order.awaiting_courier.find_by(id: order_id)
    return unless order

    order.update!(dispatch_at: [rand(DeliverySlots::PICKING).minutes.from_now, order.slot_at].max)
    enqueue_for(order)
  end

  def self.enqueue_for(order) = set(wait_until: order.dispatch_at).perform_later(order.id)

  def perform(order_id)
    order = Order.awaiting_courier.find_by(id: order_id)
    return unless order&.dispatch_at
    return self.class.enqueue_for(order) if order.dispatch_at > Time.current

    order.out_for_delivery!
    arrival = DeliverySlots::DRIVE.from_now
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order.id, identity_scope: [order.user_id],
      data: { "order_id"  => order.id,
              "status"    => "out_for_delivery",
              "eta"       => arrival.utc.iso8601,
              "eta_label" => DeliverySlots.clock_label(arrival, order.zone),
              "timezone"  => order.timezone },
    )
    OrderDeliveredJob.set(wait_until: arrival).perform_later(order.id)
  end
end
