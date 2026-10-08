# frozen_string_literal: true

require "test_helper"

class BoardClockTest < ActiveSupport::TestCase
  TOKYO    = Time.find_zone!("Asia/Tokyo")
  MONTREAL = Time.find_zone!("America/Toronto")
  NOON_UTC = Time.utc(2026, 9, 14, 12)

  test "the reader's declared zone answers, and the board's own when none is declared" do
    assert_equal "Europe/Lisbon", BoardClock.zone.name
    Kiosk::Server::CurrentRequest.with(timezone: TOKYO) do
      assert_equal "Asia/Tokyo", BoardClock.zone.name
      assert_equal "2026-09-14T21:00:00+09:00", BoardClock.publish(NOON_UTC)
    end
    assert_equal "Europe/Lisbon", BoardClock.zone.name
  end

  test "one instant reads two ways for two readers" do
    assert_equal "2026-09-14T21:00:00+09:00", BoardClock.publish(NOON_UTC, TOKYO)
    assert_equal "2026-09-14T08:00:00-04:00", BoardClock.publish(NOON_UTC, MONTREAL)
  end

  test "the board's own clock keeps daylight saving" do
    assert_equal "2026-01-14T12:00:00+00:00", BoardClock.publish(Time.utc(2026, 1, 14, 12))
    assert_equal "2026-07-14T13:00:00+01:00", BoardClock.publish(Time.utc(2026, 7, 14, 12))
  end

  test "an absent instant publishes nil" do
    assert_nil BoardClock.publish(nil)
  end
end
