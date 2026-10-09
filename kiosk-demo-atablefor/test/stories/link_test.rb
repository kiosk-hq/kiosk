# frozen_string_literal: true

require "test_helper"

class LinkStory < StoryTest
  def diego = User.find_by!(email: "diego@example.com")

  test "Diego links his assistant from the restaurant site, and the table it books is his" do
    diner = a_person(email: diego.email, password: "atablefor-demo-password").links(a_newcomer(as: Diner))
    assert_equal diego.id, diner.principal.user_id

    booking = diner.books
    assert booking.ok?, booking
    assert_equal [booking["booking_id"]], diner.bookings
    assert_equal diego.id, Booking.find(booking["booking_id"]).user_id
  end
end
