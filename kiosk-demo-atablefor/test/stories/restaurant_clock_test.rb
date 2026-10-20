# frozen_string_literal: true

require 'test_helper'

class RestaurantClockStory < StoryTest
  def tables(diner, zone = nil)
    diner.asks(:availability, headers: zone ? { 'Kiosk-Timezone' => zone } : {}, party_size: 2).rows
  end

  test 'a diner on another clock is told how far the restaurant is from them, and no seating moves' do
    diner = a_diner
    away  = tables(diner, 'America/New_York')
    home  = tables(diner, 'Europe/Lisbon')
    bare  = tables(diner)

    assert_predicate away, :any?
    assert(away.all? { it['timezone_note'].include?('runs on Europe/Lisbon time') })
    assert(away.all? { it['timezone_note'].include?('ahead of your America/New_York') })
    assert_equal bare, home
    assert_equal(bare, away.map { it.except('timezone_note') })
    assert(bare.none? { it.key?('timezone_note') })
  end
end
