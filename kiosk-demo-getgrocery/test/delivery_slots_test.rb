# frozen_string_literal: true

require 'test_helper'

class DeliverySlotsTest < ActiveSupport::TestCase
  DUBLIN = DeliverySlots.default_zone
  TOKYO  = Time.find_zone!('Asia/Tokyo')
  AUGUST_7TH    = Date.new(2026, 8, 7)

  test "windows are on the district's clock, across daylight saving" do
    assert_equal 3600, DeliverySlots.starts(AUGUST_7TH).first.utc_offset
    assert_equal 0, DeliverySlots.starts(Date.new(2026, 1, 15)).first.utc_offset
    assert_equal 9 * 3600, DeliverySlots.starts(AUGUST_7TH, TOKYO).first.utc_offset
  end

  test "a window start is one of the day's six starts on the address's clock" do
    assert DeliverySlots.start?(DUBLIN.local(2026, 8, 7, 12), DUBLIN)
    refute DeliverySlots.start?(DUBLIN.local(2026, 8, 7, 13), DUBLIN)
    refute DeliverySlots.start?(DUBLIN.local(2026, 8, 7, 12, 30), DUBLIN)
    refute DeliverySlots.start?(DUBLIN.local(2026, 8, 7, 20), DUBLIN)
  end

  test 'a window takes orders until picking and the drive no longer fit before it ends' do
    travel_to DUBLIN.local(2026, 8, 7, 11) do
      assert_equal [10, 12, 14, 16, 18], hours(AUGUST_7TH, DUBLIN)
      assert_equal [8, 10, 12, 14, 16, 18], hours(AUGUST_7TH + 1, DUBLIN)
      assert_equal [18], hours(AUGUST_7TH, TOKYO)
    end
    travel_to(DUBLIN.local(2026, 8, 7, 11, 25)) { assert_includes hours(AUGUST_7TH, DUBLIN), 10 }
    travel_to(DUBLIN.local(2026, 8, 7, 11, 26)) { assert_equal [12, 14, 16, 18], hours(AUGUST_7TH, DUBLIN) }
    travel_to(DUBLIN.local(2026, 8, 7, 6)) { assert_equal [8, 10, 12, 14, 16, 18], hours(AUGUST_7TH, DUBLIN) }
  end

  test 'the soonest day steps over a day whose windows have all closed' do
    travel_to(DUBLIN.local(2026, 8, 7, 19, 25)) { assert_equal AUGUST_7TH, DeliverySlots.soonest_date(DUBLIN) }
    travel_to(DUBLIN.local(2026, 8, 7, 19, 26)) { assert_equal AUGUST_7TH + 1, DeliverySlots.soonest_date(DUBLIN) }
  end

  test 'the label names its zone' do
    assert_equal '08:00–10:00 (Asia/Tokyo)', DeliverySlots.label(DeliverySlots.starts(AUGUST_7TH, TOKYO).first, TOKYO)
    assert_equal '08:00–10:00 (Europe/Dublin)', DeliverySlots.label(DeliverySlots.starts(AUGUST_7TH).first)
  end

  test 'every served district has a clock' do
    assert_equal DublinZones::SERVED.sort, DublinZones::ZONES.keys.sort
    assert_equal 'Europe/Dublin', DeliverySlots.zone_at('42 Camden Street, Dublin 2').name
  end

  test 'an address is routed to a served district or refused with the served list' do
    assert_equal 'D02', DublinZones.check('42 Camden Street, Dublin 2').district
    assert_equal 'D04', DublinZones.check('5 Rock Rd, Dublin 4, D04 XY45').district
    assert_equal :out_of_zone, DublinZones.check('Dublin 24').reason
    assert_equal :no_district, DublinZones.check('123 Demo Street, Dublin').reason
    assert_equal :not_dublin, DublinZones.check('10 Downing St, London').reason
    assert_equal :not_dublin, DublinZones.check('D6W').reason

    %i[no_district not_dublin out_of_zone].each do |reason|
      message = DublinZones.reject_message(DublinZones::Result.new(ok: false, district: 'D18', reason: reason))
      assert_equal DublinZones::SERVED.sort, message[/erved districts.*/].scan(/D\d\d/).uniq.sort
    end
  end

  private

  def hours(date, zone) = DeliverySlots.bookable(date, zone).map { it.in_time_zone(zone).hour }
end
