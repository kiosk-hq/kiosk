# frozen_string_literal: true

require 'test_helper'

class CourierStatesTest < ActiveSupport::TestCase
  setup do
    @shopper = User.create!(email: 'courier@example.test', password: 'conformance-fixture-password')
    @events  = Kiosk.configuration.event_store
  end

  def paid_order(window)
    Order.create!(user: @shopper, payment_status: :paid, total_cents: 449, slot_at: window,
                  address: '1 Dame Street, Dublin 2', timezone: DeliverySlots::DEFAULT_ZONE_NAME)
  end

  def emitted_by
    head = @events.head
    yield
    @events.since(@shopper.id, head)
  end

  def armed_order
    freeze_time
    paid_order(1.hour.ago).tap { CourierDispatchJob.arm!(it) }.reload
  end

  def hand_over(order)
    travel_to order.dispatch_at
    emitted_by { CourierDispatchJob.new.perform(order.id) }.sole
  end

  def deliver(order) = emitted_by { OrderDeliveredJob.new.perform(order.id) }

  test 'for an open window the courier leaves 20–30 minutes after payment and arrives five minutes later' do
    order = armed_order

    assert order.dispatch_at.between?(20.minutes.from_now, 30.minutes.from_now)

    left = hand_over(order)

    assert_predicate order.reload, :out_for_delivery?
    assert_equal({ 'topic' => 'order_delivery', 'subject' => order.id,
                   'data' => { 'order_id' => order.id, 'status' => 'out_for_delivery', 'eta' => 5.minutes.from_now.utc.iso8601,
                               'eta_label' => DeliverySlots.clock_label(5.minutes.from_now, order.zone),
                               'timezone' => DeliverySlots::DEFAULT_ZONE_NAME } },
                 left.slice('topic', 'subject', 'data'))
  end

  test 'a basket the courier carries cannot be moved' do
    order = armed_order
    hand_over(order)

    assert_not Order.reschedulable.exists?(order.id)
  end

  test 'a basket arrives once: the order reads delivered and the shopper hears it once' do
    order = armed_order
    hand_over(order)
    arrived = deliver(order).sole

    assert_predicate order.reload, :delivered?
    assert_equal({ 'order_id' => order.id, 'status' => 'delivered' }, arrived['data'])
    assert_empty deliver(order), 'a delivered basket does not arrive twice'
  end

  test 'the courier events and the order list match the published schema' do
    order = armed_order
    left = hand_over(order)
    arrived = deliver(order).sole

    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), [left, arrived])
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper
  end

  test 'for a later window the courier leaves as it opens, and not before' do
    window = 2.days.from_now.change(usec: 0)
    order  = paid_order(window)
    CourierDispatchJob.arm!(order)

    assert_equal window, order.reload.dispatch_at

    assert_empty(emitted_by { CourierDispatchJob.new.perform(order.id) })
    assert_predicate order.reload, :placed?
  end

  test 'of two runs that read the order before either hands it over, one sends the courier' do
    order = paid_order(1.hour.ago)
    first, second = Array.new(2) { Order.awaiting_courier.find(order.id) }

    assert_equal [true, false], [HandToCourierOperation.call(first), HandToCourierOperation.call(second)]
    assert_predicate second, :out_for_delivery?, 'the second run reads the row the first one saved'
    assert_not second.changed?
  end
end
