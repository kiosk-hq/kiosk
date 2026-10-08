# frozen_string_literal: true

# The basket arrives as its delivery window opens.
class OrderDeliveredJob < ApplicationJob
  queue_as :default

  def self.arrive!(order)
    wait = order.slot_at - Time.current
    wait.positive? ? set(wait: wait.seconds).perform_later(order.id) : new.perform(order.id)
  end

  def perform(order_id)
    order = Order.out_for_delivery.find_by(id: order_id)
    return unless order

    order.delivered!
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order.id, identity_scope: [order.user_id],
      data: { "order_id" => order.id, "status" => "delivered" },
    )
  end
end
