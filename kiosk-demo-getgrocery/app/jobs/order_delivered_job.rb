# frozen_string_literal: true

# The courier hands the basket over.
class OrderDeliveredJob < ApplicationJob
  queue_as :default

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
