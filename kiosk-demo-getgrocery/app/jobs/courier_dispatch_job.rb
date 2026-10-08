# frozen_string_literal: true

# The courier leaves `courier_lead_seconds` before a paid order's window opens.
class CourierDispatchJob < ApplicationJob
  queue_as :default

  # Called when an order is paid and again when its window moves; a run left
  # over from the old schedule finds the order not yet due and re-enqueues.
  def self.arm!(order_id)
    order = Order.awaiting_courier.find_by(id: order_id)
    return unless order

    order.update!(dispatch_at: order.slot_at - Rails.configuration.x.getgrocery.courier_lead_seconds)
    enqueue_for(order)
  end

  # A departure already due runs inline: on the `:async` adapter an immediate
  # enqueue would race the caller's next request.
  def self.enqueue_for(order)
    wait = order.dispatch_at - Time.current
    wait.positive? ? set(wait: wait.seconds).perform_later(order.id) : new.perform(order.id)
  end

  def perform(order_id)
    order = Order.awaiting_courier.find_by(id: order_id)
    return unless order&.dispatch_at
    return self.class.enqueue_for(order) if order.dispatch_at > Time.current

    order.out_for_delivery!
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order.id, identity_scope: [order.user_id],
      data: { "order_id"  => order.id,
              "status"    => "out_for_delivery",
              "eta"       => order.slot_at.utc.iso8601,
              "eta_label" => DeliverySlots.label(order.slot_at, order.zone),
              "timezone"  => order.timezone },
    )
    OrderDeliveredJob.arrive!(order)
  end
end
