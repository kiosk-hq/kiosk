# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  test "one principal can neither pay for, start, nor see another's reservation" do
    alice = register
    bob   = register
    alices = reserve(alice, "SK-001")
    alices_id = alices["reservation_id"]

    paid = pay(bob, alices)
    assert_equal [403, "forbidden"], [paid.status, paid.body["code"]]

    assert_equal 200, pay(alice, alices).status
    started = assistant.run(bob, name: "start_rental", reservation_id: alices_id)
    assert_equal 403, started.status

    bobs_id = reserve(bob, "SK-001")["reservation_id"]
    listed = assistant.query(bob, name: "my_reservations").body.map { _1["reservation_id"] }
    assert_equal [bobs_id], listed
    assert_equal bob.user_id, Reservation.find(bobs_id).user_id
  end

  test "the principal is not an argument" do
    alice = register
    bob   = register

    forged = assistant.run(bob, name: "reserve", scooter_code: "SK-001", user_id: alice.user_id)
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "user_id"
  end
end
