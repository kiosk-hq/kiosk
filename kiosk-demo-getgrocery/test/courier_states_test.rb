# frozen_string_literal: true

require "test_helper"

# THE TWO STATES THE SHOP WRITES ON ITS OWN reach `my_orders` in the shape it
# declares. {CourierDispatchJob} and {OrderDeliveredJob} are the only writers of
# `out_for_delivery` and `delivered`, and no call of the assistant's produces
# either, so the `status` enum is held against the writers themselves rather
# than against a fixture that copies the constant.
class CourierStatesTest < ActiveSupport::TestCase
  setup do
    @shopper = User.create!(email: "courier@example.test", password: "conformance-fixture-password")
    @order   = Order.create!(user: @shopper, status: Order::PAID, total_cents: 449,
                             slot_at: Time.current + 3600, address: "1 Dame Street, Dublin 2",
                             timezone: DeliverySlots::DEFAULT_ZONE_NAME)
    # A lead longer than the distance to the window, so the courier is due at once.
    @lead = Rails.configuration.x.getgrocery.courier_lead_seconds
    Rails.configuration.x.getgrocery.courier_lead_seconds = 2 * 60 * 60
  end

  teardown do
    Rails.configuration.x.getgrocery.courier_lead_seconds = @lead
  end

  test "an order out for delivery, then delivered, answers the declared shape" do
    CourierDispatchJob.arm!(@order.id)
    assert_equal Order::OUT_FOR_DELIVERY, @order.reload.status
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper

    OrderDeliveredJob.new.perform(@order.id)
    assert_equal Order::DELIVERED, @order.reload.status
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @shopper
  end
end
