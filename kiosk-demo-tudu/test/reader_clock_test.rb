# frozen_string_literal: true

require "test_helper"

class ReaderClockTest < ActiveSupport::TestCase
  TOKYO    = Time.find_zone!("Asia/Tokyo")
  MONTREAL = Time.find_zone!("America/Toronto")
  NOON_UTC = Time.utc(2026, 9, 14, 12)

  test "a deadline is read on the zone the caller declared, else the household's" do
    assert_equal ReaderClock::DEFAULT_ZONE_NAME, ReaderClock.zone.name
    Kiosk::Server::CurrentRequest.with(timezone: TOKYO) { assert_equal TOKYO, ReaderClock.zone }
    assert_equal ReaderClock::DEFAULT_ZONE_NAME, ReaderClock.zone.name
  end

  test "one instant reads two ways for two housemates, and names the clock" do
    assert_equal "2026-09-14T21:00:00+09:00", ReaderClock.publish(NOON_UTC, TOKYO)
    assert_equal "2026-09-14T08:00:00-04:00", ReaderClock.publish(NOON_UTC, MONTREAL)
    assert_equal "Mon 14 Sep, 21:00 (Asia/Tokyo)", ReaderClock.label(NOON_UTC, TOKYO)
    assert_nil ReaderClock.publish(nil)
    assert_nil ReaderClock.label(nil)
  end

  test "the household clock keeps daylight saving" do
    assert_equal "2026-01-14T12:00:00+00:00", ReaderClock.publish(Time.utc(2026, 1, 14, 12), ReaderClock.default_zone)
    assert_equal "2026-07-14T13:00:00+01:00", ReaderClock.publish(Time.utc(2026, 7, 14, 12), ReaderClock.default_zone)
  end

  test "the example deadline is tomorrow at 14:00 on the household clock, with its offset" do
    travel_to Time.utc(2026, 7, 14, 12) do
      assert_equal "2026-07-15T14:00:00+01:00", ReaderClock.example_due_at
    end
  end
end
