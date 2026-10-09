# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  def reschedule(shopper, order) = assistant.run(shopper, name: "reschedule_delivery", order_id: order["order_id"],
                                                       delivery_slot_id: 2, delivery_date:)

  test "one shopper can neither move nor see another's order" do
    alice = register
    bob   = register
    alices = order(alice, "banana")
    assert_equal 200, pay(alice, alices).status

    moved = reschedule(bob, alices)
    assert_equal [403, "forbidden"], [moved.status, moved.body["code"]]
    assert_equal 200, reschedule(alice, alices).status, "the same call is the owner's to make"

    bobs = order(bob, "banana")
    assert_equal [bobs["order_id"]], my_order_ids(bob)
    assert_equal [alices["order_id"]], my_order_ids(alice)
  end

  test "the principal is not an argument" do
    alice = register
    bob   = register

    forged = create_order(bob, ["banana"], user_id: alice.user_id)
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "user_id"
    assert_equal bob.user_id, Order.find(order(bob, "banana")["order_id"]).user_id
  end
end
