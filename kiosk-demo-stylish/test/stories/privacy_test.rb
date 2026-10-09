# frozen_string_literal: true

require "test_helper"

class PrivacyStory < StoryTest
  test "Alice's assistant sees Alice's appointment and not Bob's" do
    alice, bob = assistant_of(:alice), assistant_of(:bob)
    alices = alice.books["appointment_id"]
    bobs   = bob.books["appointment_id"]

    assert_equal [alices], alice.appointments
    assert_equal [bobs], bob.appointments
    assert_equal account_of(:bob), Appointment.find(bobs).user_id
  end

  test "an appointment belongs to whoever booked it, whoever the arguments name" do
    alice, bob = assistant_of(:alice), assistant_of(:bob)

    forged = bob.books(user_id: alice.principal.user_id)
    assert forged.refused?(:bad_request), forged
    assert_includes forged["detail"], "user_id"
    assert_empty Appointment.all
  end
end
