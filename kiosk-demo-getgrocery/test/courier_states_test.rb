# frozen_string_literal: true

require "test_helper"

class CourierStatesTest < ActiveSupport::TestCase
  setup do
    @shopper = User.create!(email: "courier@example.test", password: "conformance-fixture-password")
    @events  = Kiosk.configuration.event_store
  end

  def paid_order(window) = Order.create!(user: @shopper, status: "paid", total_cents: 449, slot_at: window,
                                         address: "1 Dame Street, Dublin 2", timezone: DeliverySlots::DEFAULT_ZONE_NAME)

  def events_since(head) = @events.since(@shopper.id, head)

  test "for an open window the courier leaves 20–30 minutes after payment and arrives five minutes later" do
    freeze_time
    order = paid_order(1.hour.ago)
    CourierDispatchJob.arm!(order.id)
    assert order.reload.dispatch_at.between?(20.minutes.from_now, 30.minutes.from_now)

    head = @events.head
    travel_to order.dispatch_at
    CourierDispatchJob.new.perform(order.id)
    assert_predicate order.reload, :out_for_delivery?
    left = events_since(head).sole
    assert_equal ["order_delivery", order.id], left.values_at("topic", "subject")
    assert_equal({ "order_id" => order.id, "status" => "out_for_delivery", "eta" => 5.minutes.from_now.utc.iso8601,
                   "eta_label" => DeliverySlots.clock_label(5.minutes.from_now, order.zone),
                   "timezone" => DeliverySlots::DEFAULT_ZONE_NAME }, left["data"])
    assert_not Order.reschedulable.exists?(order.id), "a basket the courier carries cannot be moved"

    head = @events.head
    OrderDeliveredJob.new.perform(order.id)
    assert_predicate order.reload, :delivered?
    arrived = events_since(head).sole
    assert_equal({ "order_id" => order.id, "status" => "delivered" }, arrived["data"])
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), [left, arrived])
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper

    head = @events.head
    OrderDeliveredJob.new.perform(order.id)
    assert_empty events_since(head), "a delivered basket does not arrive twice"
  end

  test "for a later window the courier leaves as it opens, and not before" do
    window = 2.days.from_now.change(usec: 0)
    order  = paid_order(window)
    CourierDispatchJob.arm!(order.id)
    assert_equal window, order.reload.dispatch_at

    head = @events.head
    CourierDispatchJob.new.perform(order.id)
    assert_predicate order.reload, :paid?
    assert_empty events_since(head)
  end
end
