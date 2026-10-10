# frozen_string_literal: true

require "test_helper"

class SeatingsTest < ActiveSupport::TestCase
  LISBON = Time.find_zone!("Europe/Lisbon")
  SYDNEY = Time.find_zone!("Australia/Sydney")

  test "a seating is on the restaurant's clock" do
    assert_not_equal Seatings.seating_at(Date.new(2026, 6, 15), "20:00", LISBON),
                     Seatings.seating_at(Date.new(2026, 6, 15), "20:00", SYDNEY)
    assert_equal "20:00 (Australia/Sydney)", Seatings.label("20:00", SYDNEY)
  end

  test "the roster rolls forward per restaurant clock" do
    # 22:30 on the 14th in Lisbon, 07:30 on the 15th in Sydney.
    travel_to Time.utc(2026, 6, 14, 21, 30) do
      lisbon = Seatings.upcoming(zone: LISBON)
      sydney = Seatings.upcoming(zone: SYDNEY)

      assert_equal [Date.new(2026, 6, 15), "19:00"], lisbon.first
      assert_equal [Date.new(2026, 6, 15), "19:00"], sydney.first
      assert_equal 3, sydney.count { |date, _| date == Date.new(2026, 6, 16) }
      assert_empty lisbon.select { |date, _| date == Date.new(2026, 6, 16) }
    end
  end
end
