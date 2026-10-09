# frozen_string_literal: true

require "test_helper"

class BookingStory < StoryTest
  test "a diner with no account books a table for two at eight and finds it among their bookings" do
    diner = a_diner
    table = diner.open_tables.find { _1["seating_time"] == "20:00" }

    booking = diner.books(table)
    assert booking.ok?, booking
    assert_equal ["confirmed", 2, table["seating_at"]], [booking["status"], booking["party_size"], booking["seating_at"]]
    assert_equal [booking["booking_id"]], diner.bookings

    held = Booking.find(booking["booking_id"])
    assert_equal [diner.principal.user_id, table["restaurant_table_id"], Time.iso8601(table["seating_at"])],
                 [held.user_id, held.restaurant_table_id, held.seating_at]
  end

  test "a booked table drops out of that seating, and the next diner cannot book it twice" do
    first = a_diner
    table = first.open_tables.first
    assert first.books(table).ok?

    still_open = first.open_tables.select { _1.values_at("restaurant_table_id", "seating_at") == table.values_at("restaurant_table_id", "seating_at") }
    assert_empty still_open
    assert a_diner.books(table).refused?(:conflict)
  end
end
