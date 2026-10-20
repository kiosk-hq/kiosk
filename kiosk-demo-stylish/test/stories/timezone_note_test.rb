# frozen_string_literal: true

require 'test_helper'

class TimezoneNoteStory < StoryTest
  def salons(client, zone = nil) = client.asks(:salons, headers: zone ? { 'Kiosk-Timezone' => zone } : {}).rows

  test 'a client on another clock is told how far the salon is from them, before they name an hour' do
    client = a_customer(as: Client)
    away   = salons(client, 'America/New_York').sole
    home   = salons(client, 'Europe/Paris').sole
    bare   = salons(client).sole

    assert_includes away['timezone_note'], 'Combette on Park runs on Europe/Paris time'
    assert_includes away['timezone_note'], 'ahead of your America/New_York'
    assert_equal bare, home
    assert_equal bare, away.except('timezone_note')
    assert_not bare.key?('timezone_note')
  end
end
