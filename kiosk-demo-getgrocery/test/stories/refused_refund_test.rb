# frozen_string_literal: true

require 'test_helper'

# The payment processor refuses to return the price of an item that sold out
# before the packing: the order still ships, and the shop owes the price as credit.
class RefusedRefundStory < StoryTest
  # Runs the block while the payment processor refuses every refund.
  def processor_refuses_refunds
    claim = Kiosk.configuration.payment_provider
    claim.define_singleton_method(:refund) { |**| raise Kiosk::PaymentProviders::PaymentFailed, 'refund refused' }
    yield
  ensure
    claim.singleton_class.remove_method(:refund)
  end

  # The errors Rails.error receives while the block runs, from any thread.
  def errors_reported
    reports = []
    subscriber = Object.new
    subscriber.define_singleton_method(:report) { |error, **| reports << error }
    Rails.error.subscribe(subscriber)
    yield
    reports
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  test 'an item that sold out before the packing is credit when the processor refuses its refund, the rest delivered' do
    shopper = a_shopper
    order = shopper.orders('butter-250g', 'banana')
    Product.find_by!(sku: 'butter-250g').update!(stock: 1)
    shopper.listens_for(:order_delivery)

    reported = errors_reported do
      assert_predicate processor_refuses_refunds { another_payment_takes('butter-250g') { shopper.pays_for(order) } }, :ok?
    end

    assert_instance_of Kiosk::PaymentProviders::PaymentFailed, reported.sole
    assert_equal({ 'order_id' => order['order_id'], 'status' => 'placed', 'credited_cents' => 349 },
                 shopper.hears(:order_delivery, about: order['order_id']))
    assert_equal({ 'status' => 'placed', 'payment_state' => 'paid', 'refunded_cents' => 0, 'credited_cents' => 349 },
                 shopper.orders_placed.sole.slice('status', 'payment_state', 'refunded_cents', 'credited_cents'))
    assert_predicate Order.find(order['order_id']).dispatch_at, :present?, 'the courier is booked for the rest'
  end

  test 'an order whose every item sold out is cancelled and its price is credit when the processor refuses the refund' do
    shopper = a_shopper
    order = shopper.orders('butter-250g')
    shopper.listens_for(:order_delivery)

    reported = errors_reported do
      assert_predicate processor_refuses_refunds { another_payment_takes('butter-250g') { shopper.pays_for(order) } }, :ok?
    end

    assert_instance_of Kiosk::PaymentProviders::PaymentFailed, reported.sole
    assert_equal({ 'order_id' => order['order_id'], 'status' => 'cancelled', 'credited_cents' => 349 },
                 shopper.hears(:order_delivery, about: order['order_id']))
    assert_equal({ 'status' => 'cancelled', 'payment_state' => 'paid', 'refunded_cents' => 0, 'credited_cents' => 349 },
                 shopper.orders_placed.sole.slice('status', 'payment_state', 'refunded_cents', 'credited_cents'))
  end
end
