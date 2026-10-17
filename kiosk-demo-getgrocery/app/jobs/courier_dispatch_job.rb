# frozen_string_literal: true

# The courier leaves once the basket is picked, 20–30 minutes after payment,
# and not before the order's window opens.
class CourierDispatchJob < ApplicationJob
  queue_as :default

  # Called when an order is paid and again when its window moves; a run left
  # over from the old schedule finds the order not yet due and re-enqueues.
  def self.arm!(order)
    order.update!(dispatch_at: [rand(DeliverySlots::PICKING).minutes.from_now, order.slot_at].max)
    enqueue_for(order)
  end

  def self.enqueue_for(order) = set(wait_until: order.dispatch_at).perform_later(order.id)

  def perform(order_id)
    order = Order.awaiting_courier.find_by(id: order_id)
    return unless order&.dispatch_at
    return self.class.enqueue_for(order) if order.dispatch_at > Time.current
    # Two runs can both get here after a reschedule; one hands the basket over.
    return unless order.hand_to_courier

    arrival = DeliverySlots::DRIVE.from_now
    announce_departure(order, arrival)
    OrderDeliveredJob.set(wait_until: arrival).perform_later(order.id)
  end

  private

  def announce_departure(order, arrival)
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order.id, identity_scope: [order.user_id],
      data: { 'order_id' => order.id,
              'status' => 'out_for_delivery',
              'eta' => arrival.utc.iso8601,
              'eta_label' => DeliverySlots.clock_label(arrival, order.zone),
              'timezone' => order.timezone }
    )
  end
end
