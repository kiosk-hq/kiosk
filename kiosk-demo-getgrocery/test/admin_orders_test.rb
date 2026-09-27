# frozen_string_literal: true

require "test_helper"

# The operator's order list names the shop's own two states. Both are reached by
# the shipped flow and neither is a settlement fact, so a page that read only the
# settlement showed a delivered basket as merely paid.
class AdminOrdersTest < ActionDispatch::IntegrationTest
  setup do
    shopper = User.create!(email: "admin@example.test", password: "conformance-fixture-password")
    [Order::OUT_FOR_DELIVERY, Order::DELIVERED].each do |status|
      Order.create!(user: shopper, status: status, total_cents: 449,
                    slot_at: Time.current, address: "1 Dame Street, Dublin 2",
                    timezone: DeliverySlots::DEFAULT_ZONE_NAME)
    end
  end

  test "an order with the courier, and a delivered one, each wear their own badge" do
    get admin_orders_path

    assert_response :success
    assert_select ".badge-out-for-delivery", text: "OUT FOR DELIVERY", count: 1
    assert_select ".badge-delivered", text: "DELIVERED", count: 1
  end
end
