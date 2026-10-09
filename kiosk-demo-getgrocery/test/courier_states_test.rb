# frozen_string_literal: true

require "test_helper"

# The shop's own two transitions: the courier leaves `courier_lead_seconds`
# before a paid order's window opens, and the basket arrives as it opens.
class CourierStatesTest < ActiveSupport::TestCase
  LEAD = 2 * 60 * 60

  setup do
    @shopper = User.create!(email: "courier@example.test", password: "conformance-fixture-password")
    @lead = Rails.configuration.x.getgrocery.courier_lead_seconds
    Rails.configuration.x.getgrocery.courier_lead_seconds = LEAD
    @events = Kiosk.configuration.event_store
  end

  teardown { Rails.configuration.x.getgrocery.courier_lead_seconds = @lead }

  def paid_order(window) = Order.create!(user: @shopper, status: "paid", total_cents: 449, slot_at: window,
                                         address: "1 Dame Street, Dublin 2", timezone: DeliverySlots::DEFAULT_ZONE_NAME)

  def events_since(head) = @events.since(@shopper.id, head)

  test "a courier due before the window leaves at once, with the window as its ETA, and the basket then arrives" do
    window = 1.hour.from_now.change(usec: 0)
    order  = paid_order(window)
    head   = @events.head

    CourierDispatchJob.arm!(order.id)
    order.reload
    assert_equal ["out_for_delivery", window - LEAD], [order.status, order.dispatch_at]
    left = events_since(head).sole
    assert_equal ["order_delivery", order.id], left.values_at("topic", "subject")
    assert_equal({ "order_id" => order.id, "status" => "out_for_delivery", "eta" => window.utc.iso8601,
                   "eta_label" => DeliverySlots.label(window, DeliverySlots.default_zone),
                   "timezone" => DeliverySlots::DEFAULT_ZONE_NAME }, left["data"])
    assert_not Order.reschedulable.exists?(order.id), "a basket the courier carries cannot be moved"
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper

    head = @events.head
    OrderDeliveredJob.new.perform(order.id)
    assert_equal "delivered", order.reload.status
    arrived = events_since(head).sole
    assert_equal({ "order_id" => order.id, "status" => "delivered" }, arrived["data"])
    assert_empty Kiosk::Redteam::EventStream.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), [left, arrived])
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper

    head = @events.head
    OrderDeliveredJob.new.perform(order.id)
    assert_empty events_since(head), "a delivered basket does not arrive twice"
  end

  test "a window days away arms a courier that does not leave, even when an old schedule fires" do
    order = paid_order(2.days.from_now)
    CourierDispatchJob.arm!(order.id)
    assert_operator order.reload.dispatch_at, :>, Time.current

    head = @events.head
    CourierDispatchJob.new.perform(order.id)
    assert_equal "paid", order.reload.status
    assert_empty events_since(head)
  end
end
