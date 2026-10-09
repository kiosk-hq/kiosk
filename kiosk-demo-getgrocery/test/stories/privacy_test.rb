# frozen_string_literal: true

require "test_helper"

class PrivacyStory < StoryTest
  test "one shopper can neither move nor see another's delivery" do
    alice, bob = a_shopper, a_shopper
    alices = alice.orders("banana")
    assert alice.pays_for(alices).ok?

    assert bob.moves(alices, to_window: 2).refused?(:forbidden)
    assert alice.moves(alices, to_window: 2).ok?

    bobs = bob.orders("banana")
    assert_equal [bobs["order_id"]], bob.orders_placed.pluck("order_id")
    assert_equal [alices["order_id"]], alice.orders_placed.pluck("order_id")
  end

  test "an order belongs to the shopper who placed it, whoever the arguments name" do
    alice, bob = a_shopper, a_shopper

    forged = bob.orders("banana", user_id: alice.principal.user_id)
    assert forged.refused?(:bad_request)
    assert_includes forged["detail"], "user_id"
    assert_equal bob.principal.user_id, Order.find(bob.orders("banana")["order_id"]).user_id
  end
end
