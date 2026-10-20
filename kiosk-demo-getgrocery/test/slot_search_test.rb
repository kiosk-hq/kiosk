# frozen_string_literal: true

require 'test_helper'

class SlotSearchTest < ActiveSupport::TestCase
  SHOP    = DeliverySlots.default_zone
  ADDRESS = '42 Camden Street, Dublin 2'
  # 00:30 on the 8th in Dublin, still the 7th in UTC and far west of it.
  AFTER_MIDNIGHT = Time.utc(2026, 9, 7, 23, 30)

  def search(**arguments) = SlotSearch.new(delivery_address: ADDRESS, **arguments)

  test 'an address outside the served districts is refused with the reason' do
    assert_equal 'D02', search.district
    assert_match(/\Adelivery_address is in D24, which getgrocery does not deliver to/,
                 search(delivery_address: 'Dublin 24').tap(&:validate).errors.full_messages.sole)
  end

  test "a named day is a day on the address's clock" do
    travel_to AFTER_MIDNIGHT do
      assert_equal Date.new(2026, 9, 9), search(date: '2026-09-09').day
      assert_not search(date: '2026-09-07').valid?
    end
  end

  test 'a day that has ended at the address is refused naming its zone' do
    travel_to AFTER_MIDNIGHT do
      message = search(date: '2026-09-07').tap(&:validate).errors.full_messages.sole

      assert_includes message, "date 2026-09-07 is in the past at the delivery address (#{SHOP.name})"
      assert_includes message, 'the earliest day you can ask for is 2026-09-08'
    end
  end

  test 'no date is the soonest day the shop delivers' do
    travel_to SHOP.local(2026, 9, 7, 21) do
      assert_equal Date.new(2026, 9, 8), search.day
    end
  end

  test "a caller's zone is only what it declares" do
    hints = { 'HTTP_ACCEPT_LANGUAGE' => 'ro-RO', 'HTTP_CF_IPCOUNTRY' => 'RO', 'REMOTE_ADDR' => '5.2.0.1' }

    assert_nil Kiosk::Server::CallerTimezone.from_env(hints)
    assert_raises(Kiosk::Server::Errors::BadRequest) { Kiosk::Server::CallerTimezone.from_value('+03:00') }
  end
end
