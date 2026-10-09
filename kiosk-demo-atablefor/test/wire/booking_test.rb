# frozen_string_literal: true

require "test_helper"

class BookingTest < WireTest
  test "an assistant books a table for two tonight at eight and finds it in my_bookings" do
    diner = register
    table = open_tables(diner).find { _1["seating_time"] == "20:00" }

    booked = book(diner, table)
    assert_equal 200, booked.status, booked.body
    assert_equal({ "status" => "confirmed", "party_size" => 2, "seating_at" => table["seating_at"] },
                 booked.body.slice("status", "party_size", "seating_at"))
    assert_equal [booked.body["booking_id"]], my_booking_ids(diner)

    booking = Booking.find(booked.body["booking_id"])
    assert_equal [diner.user_id, table["restaurant_table_id"], Time.iso8601(table["seating_at"])],
                 [booking.user_id, booking.restaurant_table_id, booking.seating_at]
  end

  test "a booked table leaves availability for that seating and cannot be booked twice" do
    diner = register
    table = open_tables(diner).first
    assert_equal 200, book(diner, table).status

    taken = open_tables(diner).select { _1.values_at("restaurant_table_id", "seating_at") == table.values_at("restaurant_table_id", "seating_at") }
    assert_empty taken
    again = book(register, table)
    assert_equal [409, "conflict"], [again.status, again.body["code"]]
  end
end
