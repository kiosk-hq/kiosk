# frozen_string_literal: true

require "test_helper"

class WireArgumentsTest < ActiveSupport::TestCase
  SHOP     = DeliverySlots.default_zone
  LISBON_CALLER   = Time.find_zone!("Europe/Lisbon")
  BUCHAREST_CALLER = Time.find_zone!("Europe/Bucharest")
  THE_7TH  = Date.new(2026, 9, 7)

  def refusal(&) = assert_raises(Kiosk::Server::Errors::BadRequest, &)

  test "an address outside the served districts is refused with the reason" do
    assert_equal "D02", WireArguments.served_district("42 Camden Street, Dublin 2")
    assert_match(/does not deliver to/, refusal { WireArguments.served_district("Dublin 24") }.message)
    assert_match(/missing delivery_address/, refusal { WireArguments.served_district("") }.message)
  end

  test "a delivery date is a real day that has not passed at the address" do
    travel_to SHOP.local(2026, 9, 7, 12) do
      assert_equal Date.new(2026, 9, 8), WireArguments.delivery_date("2026-09-08", zone: SHOP)
      assert_match(/invalid delivery_date/, refusal { WireArguments.delivery_date("2026-02-30", zone: SHOP) }.message)
      assert_match(/in the past/, refusal { WireArguments.delivery_date("2026-09-06", zone: SHOP) }.message)
    end
  end

  test "a window that has begun cannot be booked" do
    travel_to SHOP.local(2026, 9, 7, 11) do
      assert_match(/already started/, refusal { WireArguments.bookable_slot!(THE_7TH, 2, SHOP) }.message)
      assert_nil WireArguments.bookable_slot!(THE_7TH, 3, SHOP)
    end
  end

  test "a cart total must fit the orders table" do
    assert_nil WireArguments.priceable_total!(WireArguments::MAX_INT4)
    error = refusal { WireArguments.priceable_total!(WireArguments::MAX_INT4 + 1) }
    assert_match(/split the cart/, error.hint)
  end

  # 22:30 UTC: 23:30 in Dublin and Lisbon, 01:30 on the 8th in Bucharest.
  test "the day a caller names is read on its declared calendar" do
    travel_to Time.utc(2026, 9, 7, 22, 30) do
      soonest = DeliverySlots.soonest_date(SHOP)

      assert_equal Date.new(2026, 9, 8), WireArguments.caller_day(THE_7TH, zone: SHOP, caller_zone: nil, soonest: soonest)
      assert_equal Date.new(2026, 9, 8), WireArguments.caller_day(THE_7TH, zone: SHOP, caller_zone: LISBON_CALLER, soonest: soonest)

      message = refusal { WireArguments.caller_day(THE_7TH, zone: SHOP, caller_zone: BUCHAREST_CALLER, soonest: soonest) }.message
      assert_includes message, "2026-09-07"
      assert_includes message, BUCHAREST_CALLER.name
      assert_includes message, "2026-09-08"
      assert_not_includes message, SHOP.name
    end
  end

  test "a caller's zone is only what it declares" do
    hints = { "HTTP_ACCEPT_LANGUAGE" => "ro-RO", "HTTP_CF_IPCOUNTRY" => "RO", "REMOTE_ADDR" => "5.2.0.1" }
    assert_nil Kiosk::Server::CallerTimezone.from_env(hints)
    assert_raises(Kiosk::Server::Errors::BadRequest) { Kiosk::Server::CallerTimezone.from_value("+03:00") }
  end
end
