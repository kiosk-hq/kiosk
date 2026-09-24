# frozen_string_literal: true

# THE BASKET IS AT THE DOOR. The second half of a delivery this shop, and not
# the caller, is carrying out — see {CourierDispatchJob} for the first.
#
# It is a separate job rather than a `sleep` inside that one because the two
# are separately true: a courier that has left is a fact whether or not the
# process survives long enough to see the arrival, and a demo that conflated
# them would teach an adopter to hold a worker thread for the length of a
# delivery.
#
# THERE IS NO SECOND NUMBER HERE. The courier leaves `courier_lead_seconds`
# before the window and arrives as it opens, so the arrival time is the window
# itself — the one this shop already published on `delivery_slots`, on
# `create_order` and on `my_orders`. A road-time setting beside it would be a
# second source of truth for «when does this land», and the two would disagree
# the first time either moved.
class OrderDeliveredJob < ApplicationJob
  queue_as :default

  # An arrival already due happens inline, for the reason {CourierDispatchJob}
  # states about a departure already due: `:async` runs a job on a thread pool,
  # so «enqueue with no delay» races the next HTTP call.
  def self.arrive!(order_id, slot_at)
    wait = (slot_at || Time.current) - Time.current
    return new.perform(order_id) if wait <= 0

    set(wait: wait.seconds).perform_later(order_id)
  end

  def perform(order_id)
    order = Order.where(id: order_id).pick(:user_id, :status)
    return unless order

    user_id, status = order
    # Only a basket a courier is actually carrying can arrive, and arriving
    # twice is not a thing. A row that moved on since the departure — it was
    # delivered by an earlier run — is left exactly as it is.
    return unless status == Order::OUT_FOR_DELIVERY

    Order.where(id: order_id).update_all(status: Order::DELIVERED, updated_at: Time.current)

    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order_id, identity_scope: [user_id],
      data: { "order_id" => order_id, "status" => "delivered" },
    )
  end
end
