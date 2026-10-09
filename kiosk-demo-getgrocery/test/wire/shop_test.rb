# frozen_string_literal: true

require "test_helper"

class ShopTest < WireTest
  test "an assistant with no human orders groceries for a delivery window and pays for them" do
    shopper = register
    products = assistant.query(shopper, name: "catalog").body
    assert products.all? { _1["currency"] == "eur" && _1["price_eur"].start_with?("€") }
    skus = products.first(3).map { _1["sku"] }

    slots = assistant.query(shopper, name: "delivery_slots", delivery_address: DELIVERY_ADDRESS)
    assert_equal 200, slots.status, slots.body
    slot = slots.body.first
    assert_equal "D02", slot["district"]
    assert_equal "Europe/Dublin", slot["timezone"]
    assert_includes slot["label"], "(Europe/Dublin)"

    placed = assistant.run(shopper, name: "create_order", items: skus.map { { sku: _1, qty: 1 } },
                                 delivery_slot_id: slot["delivery_slot_id"], delivery_date: slot["date"],
                                 delivery_address: DELIVERY_ADDRESS)
    assert_equal 200, placed.status, placed.body
    order = placed.body.merge("skus" => skus)
    assert_equal [slot["slot_at"], "eur"], order.values_at("slot_at", "currency")
    assert_equal products.first(3).sum { _1["price_cents"] }, order["total_cents"]
    assert_predicate order["pay_hint"], :present?

    setup = assistant.run(shopper, name: "payment_setup")
    assert_equal [200, "ready"], [setup.status, setup.body["status"]]

    paid = pay(shopper, order)
    assert_equal 200, paid.status, paid.body
    assert_equal [order["total_cents"], "eur"], paid.body.values_at("settled_amount_cents", "currency")
    assert_match(/\Api_/, paid.body["psp_reference"])
    assert_predicate paid.body["settlement_id"], :present?

    mine = assistant.query(shopper, name: "my_orders").body.find { _1["order_id"] == order["order_id"] }
    assert_equal "paid", mine["payment_state"]
    stored = Order.find(order["order_id"])
    assert_equal [Time.iso8601(slot["slot_at"]), "Europe/Dublin", 3], [stored.slot_at, stored.timezone, stored.order_items.count]
    assert mine["slot_label"].end_with?("(#{stored.timezone})"), mine["slot_label"]
    assert_equal 1, Kiosk::Settlement.where(user_id: shopper.user_id).count
  end

  test "a caller's own today is answered on the shop's calendar" do
    shopper = register
    today = assistant.query(shopper, name: "delivery_slots", headers: { "Kiosk-Timezone" => "UTC" },
                                  delivery_address: DELIVERY_ADDRESS, date: Time.now.utc.to_date.iso8601)
    assert_equal 200, today.status, today.body
    assert_not_empty today.body
  end

  test "an address with no served district is refused before any window is shown" do
    refused = assistant.query(register, name: "delivery_slots", delivery_address: "123 Demo Street, Dublin")
    assert_equal [400, "bad_request"], [refused.status, refused.body["code"]]
  end

  test "a settled order is not paid twice" do
    shopper = register
    order = order(shopper, "banana")
    assert_equal 200, pay(shopper, order).status

    again = pay(shopper, order)
    assert_equal [403, "forbidden"], [again.status, again.body["code"]]
    assert_equal 1, Kiosk::Settlement.where(user_id: shopper.user_id).count
  end
end
