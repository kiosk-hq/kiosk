# frozen_string_literal: true

require "test_helper"

class SalonBookStory < StoryTest
  test "the owner's assistant sees every booking and what they will bring in" do
    alices = assistant_of(:alice).books("Colour")["appointment_id"]
    bobs   = assistant_of(:bob).books("Cut")["appointment_id"]
    owner  = assistant_of(:owner)
    assert_equal "owner", owner.role

    *bookings, forecast = owner.the_book.rows
    assert_equal [alices, bobs].sort, bookings.pluck("id").sort
    assert_equal ["forecast", 2, 12_500], forecast.values_at("summary", "bookings", "forecast_cents")
  end

  test "a client's assistant sees only the client's own booking and no forecast" do
    alice  = assistant_of(:alice)
    alices = alice.books["appointment_id"]
    assistant_of(:bob).books
    assert_equal "customer", alice.role

    assert_equal [[alices, "booking"]], alice.the_book.rows.map { _1.values_at("id", "kind") }
  end
end
