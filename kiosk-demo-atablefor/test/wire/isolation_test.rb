# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  test "one diner can neither cancel nor see another's booking" do
    alice = register
    bob   = register
    alices = book(alice).body["booking_id"]

    cancelled = assistant.run(bob, name: "cancel_booking", booking_id: alices)
    assert_equal [403, "forbidden"], [cancelled.status, cancelled.body["code"]]
    assert_predicate Booking.find(alices), :confirmed?

    bobs = book(bob).body["booking_id"]
    assert_equal [bobs], my_booking_ids(bob)
    assert_equal [alices], my_booking_ids(alice)
    assert_equal bob.user_id, Booking.find(bobs).user_id
  end

  test "the principal is not an argument" do
    alice = register
    bob   = register
    table = open_tables(bob).first

    forged = assistant.run(bob, name: "book_table", user_id: alice.user_id, party_size: 2,
                             restaurant_id: table["restaurant_id"], restaurant_table_id: table["restaurant_table_id"],
                             date: table["seating_date"], time: table["seating_time"])
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "user_id"
  end
end
