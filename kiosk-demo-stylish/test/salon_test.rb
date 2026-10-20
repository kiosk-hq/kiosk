# frozen_string_literal: true

require 'test_helper'

class SalonTest < ActiveSupport::TestCase
  test 'a timezone note names the hours between the two clocks, in one sentence' do
    combette = Salon.new(name: 'Combette on Park', timezone: 'Europe/Paris')

    travel_to Time.utc(2026, 1, 15, 12) do
      assert_equal 'Combette on Park runs on Europe/Paris time, 6 hours ahead of your America/New_York. ' \
                   "Every hour you book here is on the salon's clock.",
                   combette.timezone_note(Time.find_zone!('America/New_York'))
      assert_includes combette.timezone_note(Time.find_zone!('Asia/Kolkata')), '4.5 hours behind your Asia/Kolkata'
    end
  end

  test 'a timezone note says nothing to a caller on the same clock, or one that declared none' do
    combette = Salon.new(name: 'Combette on Park', timezone: 'Europe/Paris')

    assert_nil combette.timezone_note(Time.find_zone!('Europe/Berlin'))
    assert_nil combette.timezone_note(nil)
  end
end
