# frozen_string_literal: true

require "test_helper"

class PrivacyStory < StoryTest
  test "one diner can neither cancel nor see another's booking" do
    alice, bob = a_diner, a_diner
    alices = alice.books

    assert bob.cancels(alices).refused?(:forbidden)
    assert_predicate Booking.find(alices["booking_id"]), :confirmed?

    bobs = bob.books
    assert_equal [bobs["booking_id"]], bob.bookings
    assert_equal [alices["booking_id"]], alice.bookings
    assert_equal bob.principal.user_id, Booking.find(bobs["booking_id"]).user_id
  end

  test "a booking belongs to the diner who made it, whoever the arguments name" do
    alice, bob = a_diner, a_diner

    forged = bob.books(user_id: alice.principal.user_id)
    assert forged.refused?(:bad_request)
    assert_includes forged["detail"], "user_id"
  end
end
