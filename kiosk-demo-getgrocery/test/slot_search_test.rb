# frozen_string_literal: true

require "test_helper"

class SlotSearchTest < ActiveSupport::TestCase
  SHOP             = DeliverySlots.default_zone
  LISBON_CALLER    = Time.find_zone!("Europe/Lisbon")
  BUCHAREST_CALLER = Time.find_zone!("Europe/Bucharest")
  ADDRESS          = "42 Camden Street, Dublin 2"

  def search(**arguments) = SlotSearch.new(delivery_address: ADDRESS, **arguments)

  test "an address outside the served districts is refused with the reason" do
    assert_equal "D02", search.district
    assert_match(/\Adelivery_address is in D24, which getgrocery does not deliver to/,
                 search(delivery_address: "Dublin 24").tap(&:validate).errors.full_messages.sole)
  end

  # 22:30 UTC: 23:30 in Dublin and Lisbon, 01:30 on the 8th in Bucharest.
  test "the day a caller names is read on its declared calendar" do
    travel_to Time.utc(2026, 9, 7, 22, 30) do
      assert_equal Date.new(2026, 9, 8), search(date: "2026-09-07").day
      assert_equal Date.new(2026, 9, 8), search(date: "2026-09-07", caller_zone: LISBON_CALLER).day

      refused = search(date: "2026-09-07", caller_zone: BUCHAREST_CALLER)
      assert_not refused.valid?
      message = refused.errors.full_messages.sole
      assert_includes message, "date 2026-09-07 is in the past on the calendar it is read in (Europe/Bucharest)"
      assert_includes message, "the earliest day you can ask for is 2026-09-08"
      assert_not_includes message, SHOP.name
    end
  end

  test "no date is the soonest day the shop delivers" do
    travel_to SHOP.local(2026, 9, 7, 21) do
      assert_equal Date.new(2026, 9, 8), search.day
    end
  end

  test "a caller's zone is only what it declares" do
    hints = { "HTTP_ACCEPT_LANGUAGE" => "ro-RO", "HTTP_CF_IPCOUNTRY" => "RO", "REMOTE_ADDR" => "5.2.0.1" }
    assert_nil Kiosk::Server::CallerTimezone.from_env(hints)
    assert_raises(Kiosk::Server::Errors::BadRequest) { Kiosk::Server::CallerTimezone.from_value("+03:00") }
  end
end
