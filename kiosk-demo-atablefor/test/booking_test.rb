# frozen_string_literal: true

require "test_helper"

class BookingTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Tasca de Teste", timezone: "Europe/Lisbon")
    @table      = @restaurant.restaurant_tables.create!(label: "T1", capacity: 4)
  end

  def booking(**attributes)
    Booking.new(user: User.create!, restaurant_table: @table, party_size: 2,
                seating_at: @restaurant.seating(Date.new(2026, 9, 1), 20), status: :confirmed, **attributes)
  end

  def errors(booking) = booking.tap(&:validate).errors.full_messages

  test "a booking is for one of the restaurant's upcoming seatings" do
    travel_to @restaurant.seating(Date.new(2026, 9, 1), 19).change(min: 30) do
      assert_empty errors(booking)
      assert_equal ["seating_at 2026-09-01 19:00 has already started; pick an upcoming seating from availability"],
                   errors(booking(seating_at: @restaurant.seating(Date.new(2026, 9, 1), 19)))
      assert_equal ["seating_at 2026-09-05 20:00 is not an upcoming seating; currently 2026-09-01 20:00, " \
                    "2026-09-01 21:00, 2026-09-02 19:00, 2026-09-02 20:00, 2026-09-02 21:00"],
                   errors(booking(seating_at: @restaurant.seating(Date.new(2026, 9, 5), 20)))
    end
  end

  test "a booking is at its table's restaurant, and the table seats the party" do
    travel_to @restaurant.seating(Date.new(2026, 9, 1), 12) do
      assert_equal ["T1 seats 4; pick a larger table from availability"], errors(booking(party_size: 5))

      elsewhere = Restaurant.create!(name: "Elsewhere").restaurant_tables.create!(label: "E1", capacity: 8)
      assert_equal elsewhere.restaurant, booking(restaurant_table: elsewhere).tap(&:validate).restaurant
    end
  end

  test "a party is one to twenty guests" do
    travel_to @restaurant.seating(Date.new(2026, 9, 1), 12) do
      assert_includes errors(booking(party_size: 21)), "party_size must be in 1..20"
    end
  end

  test "a cancellation is not held to the seating rules" do
    held = travel_to(@restaurant.seating(Date.new(2026, 9, 1), 12)) { booking.tap(&:save!) }

    travel_to @restaurant.seating(Date.new(2026, 9, 2), 12) do
      assert held.cancelled!
    end
  end
end
