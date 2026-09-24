# frozen_string_literal: true

# THE COURIER LEAVES, shortly before the window this shop published.
#
# Everything else in this demo happens because a caller asked for it. This does
# not: the basket is paid, the window is hours away, and the one thing an
# assistant would like to tell its human — «it is on its way» — is a fact only
# the shop holds, at a moment nobody can predict well enough to poll for.
#
# The lead is a DEMO NUMBER, published rather than hidden: 10 to 15 minutes,
# drawn once per order and recorded as `dispatch_at` so the pending work is
# legible in the orders table instead of only inside a thread pool.
class CourierDispatchJob < ApplicationJob
  queue_as :default

  # ARM THE COURIER FOR A PAID ORDER. Called when the money lands and again
  # whenever the window moves, because a rescheduled order departs against its
  # NEW window; re-arming writes a new `dispatch_at` and enqueues against it,
  # and the run that the old schedule still produces finds the row not yet due
  # and re-enqueues itself rather than delivering early.
  def self.arm!(order_id)
    order = Order.where(id: order_id).pick(:slot_at, :status)
    return unless order

    slot_at, status = order
    return unless slot_at && Order::AWAITING_COURIER.include?(status)

    dispatch_at = slot_at - lead_seconds
    Order.where(id: order_id).update_all(dispatch_at: dispatch_at, updated_at: Time.current)
    enqueue_for(order_id, dispatch_at)
  rescue StandardError => e
    # A lost courier must never surface as a failed CHARGE or a failed move:
    # the money is already recorded by the engine's settlement, and the window
    # is already written on the row.
    Rails.logger.warn("[getgrocery] could not arm the courier: #{e.class}")
    nil
  end

  # A DEPARTURE ALREADY DUE HAPPENS INLINE, and that is not a shortcut — it is
  # what makes the flow assertable AND what an order placed for the very next
  # window actually means. The `:async` adapter runs a job on a thread pool, so
  # «enqueue with no delay» and «the next HTTP call» race; a flow that read the
  # event straight after paying would pass or fail on scheduler timing.
  def self.enqueue_for(order_id, dispatch_at)
    wait = dispatch_at - Time.current
    return new.perform(order_id) if wait <= 0

    set(wait: wait.seconds).perform_later(order_id)
  end

  # 10–15 minutes, the shipped numbers. Configuration rather than literals here
  # because a suite has to be able to collapse the wait: a flow that waited a
  # real twelve minutes for an assertion is a flow nobody runs, and a gate
  # nobody runs is a gate that is not there.
  def self.lead_seconds
    Rails.configuration.x.getgrocery.courier_lead_seconds.to_i
  end

  def perform(order_id)
    order = Order.where(id: order_id).pick(:user_id, :status, :dispatch_at, :slot_at, :timezone)
    return unless order

    user_id, status, dispatch_at, slot_at, timezone = order
    # The courier has already left, or the basket is not paid. Either way this
    # is a run of a schedule the world moved past; departing is a transition and
    # it happens once.
    return unless Order::AWAITING_COURIER.include?(status)
    return unless dispatch_at

    # THE WINDOW MOVED AFTER THIS RUN WAS SCHEDULED. Re-arming already wrote the
    # new `dispatch_at`; this run is the old schedule arriving, so hand it back
    # to the new one instead of sending a courier a day early.
    return self.class.enqueue_for(order_id, dispatch_at) if dispatch_at > Time.current

    Order.where(id: order_id)
         .update_all(status: Order::OUT_FOR_DELIVERY, updated_at: Time.current)

    zone = Time.find_zone(timezone) || Time.zone
    Kiosk::Server::Events.emit(
      topic: :order_delivery, subject: order_id, identity_scope: [user_id],
      data: { "order_id"    => order_id,
              "status"      => "out_for_delivery",
              "eta"         => slot_at.utc.iso8601,
              "eta_label"   => DeliverySlots.label(slot_at, zone),
              "timezone"    => zone.name },
    )

    OrderDeliveredJob.arrive!(order_id, slot_at)
  end
end
