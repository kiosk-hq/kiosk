# frozen_string_literal: true

require 'test_helper'

class RestaurantTest < ActiveSupport::TestCase
  test "a seating is the hour on the restaurant's own clock, across a DST change" do
    lisbon = Restaurant.new(timezone: 'Europe/Lisbon')

    assert_equal '2026-03-29T20:00:00+01:00', lisbon.seating(Date.new(2026, 3, 29), 20).iso8601
    assert_equal '2026-03-28T20:00:00+00:00', lisbon.seating(Date.new(2026, 3, 28), 20).iso8601
  end

  test "the upcoming seatings roll forward on each restaurant's clock" do
    lisbon = Restaurant.new(timezone: 'Europe/Lisbon')
    sydney = Restaurant.new(timezone: 'Australia/Sydney')

    # 22:30 on the 14th in Lisbon, 07:30 on the 15th in Sydney.
    travel_to Time.utc(2026, 6, 14, 21, 30) do
      assert_equal %w[2026-06-15T19:00:00+01:00 2026-06-15T20:00:00+01:00 2026-06-15T21:00:00+01:00],
                   lisbon.upcoming_seatings.first(3).map(&:iso8601)
      assert_equal([39, 42], [lisbon, sydney].map { it.upcoming_seatings.size })
    end
  end

  test 'a seating that has started is no longer upcoming' do
    lisbon = Restaurant.new(timezone: 'Europe/Lisbon')

    travel_to lisbon.seating(Date.new(2026, 9, 1), 20) do
      assert_equal(%w[21:00 19:00 20:00 21:00], lisbon.upcoming_seatings(days: 2).map { it.strftime('%H:%M') })
    end
  end

  test 'a seating label names the zone it is read on' do
    assert_equal 'Mon 15 Jun, 20:00 (Australia/Sydney)',
                 Restaurant.seating_label(Restaurant.new(timezone: 'Australia/Sydney').seating(Date.new(2026, 6, 15), 20))
  end

  test 'a timezone note names the hours between the two clocks, in one sentence' do
    tasca = Restaurant.new(name: 'Tasca do Tejo', timezone: 'Europe/Lisbon')

    travel_to Time.utc(2026, 1, 15, 12) do
      assert_equal 'Tasca do Tejo runs on Europe/Lisbon time, 3 hours behind your Europe/Istanbul. ' \
                   "Every date and time here is the restaurant's.",
                   tasca.timezone_note(Time.find_zone!('Europe/Istanbul'))
      assert_includes tasca.timezone_note(Time.find_zone!('Atlantic/Azores')), '1 hour ahead of your Atlantic/Azores'
    end
  end

  test 'a timezone note says nothing to a caller on the same clock, or one that declared none' do
    tasca = Restaurant.new(name: 'Tasca do Tejo', timezone: 'Europe/Lisbon')

    assert_nil tasca.timezone_note(Time.find_zone!('Europe/London'))
    assert_nil tasca.timezone_note(nil)
  end
end
