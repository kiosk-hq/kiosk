# frozen_string_literal: true

require "test_helper"

class ShopStory < StoryTest
  test "a shopper with no account orders groceries for tomorrow morning and pays" do
    shopper = a_shopper
    groceries = shopper.browses.rows.first(3)
    window = shopper.delivery_windows(date: (Date.current + 1).iso8601).rows.first
    assert_equal "08:00–10:00 (Europe/Dublin)", window["label"]

    order = shopper.orders(*groceries.pluck("sku"), window: window["delivery_slot_id"])
    assert order.ok?, order
    assert_equal groceries.sum { _1["price_cents"] }, order["total_cents"]

    assert shopper.pays_for(order).ok?
    placed = shopper.orders_placed.find { _1["order_id"] == order["order_id"] }
    assert_equal ["paid", "08:00–10:00 (Europe/Dublin)"], placed.values_at("payment_state", "slot_label")
  end

  test "a paid order is not charged again" do
    shopper = a_shopper
    order = shopper.orders("banana")
    assert shopper.pays_for(order).ok?

    assert shopper.pays_for(order).refused?(:forbidden)
    assert_equal 1, Kiosk::Settlement.where(user_id: shopper.principal.user_id).count
  end

  test "an address outside the delivery area gets no delivery windows" do
    assert a_shopper.delivery_windows(address: "123 Demo Street, Dublin").refused?(:bad_request)
  end

  test "a shopper whose clock is past midnight in UTC still sees today's Dublin windows" do
    today = a_shopper.delivery_windows(headers: { "Kiosk-Timezone" => "UTC" }, date: Time.now.utc.to_date.iso8601)
    assert today.ok?, today
    assert_not_empty today.rows
  end
end
