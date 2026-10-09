# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  test "each human's assistant sees its own appointments and no one else's" do
    alice = bind("alice@example.com")
    bob   = bind("bob@example.com")
    alices = book(alice)["appointment_id"]
    bobs   = book(bob)["appointment_id"]

    assert_equal [alices], my_appointments(alice)
    assert_equal [bobs], my_appointments(bob)
    assert_equal bob.user_id, Appointment.find(bobs).user_id
  end

  test "the principal is not an argument" do
    alice = bind("alice@example.com")
    bob   = bind("bob@example.com")

    forged = assistant.run(bob, name: "book_appointment", salon_id: Salon.first.id, slot: 1.week.from_now.iso8601,
                             user_id: alice.user_id)
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "user_id"
    assert_empty Appointment.all
  end
end
