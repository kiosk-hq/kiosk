# frozen_string_literal: true

require 'story_helper'

RSpec.describe "A hotel on another clock than the guest's", type: :story do
  def detail(guest, hotel, zone = nil)
    headers = zone ? { 'Kiosk-Timezone' => zone } : {}
    guest.asks(:hotel_detail, headers:, property_id: hotel['property_id'],
                              check_in: (Date.current + 30).iso8601, check_out: (Date.current + 33).iso8601)
  end

  it 'tells a guest on another clock how far the hotel is from them, and moves no date' do
    guest = a_guest
    hotel = guest.browses_hotels.rows.first
    away  = detail(guest, hotel, 'America/New_York').rows.sole
    home  = detail(guest, hotel, 'Europe/Istanbul').rows.sole
    bare  = detail(guest, hotel).rows.sole

    expect(away['timezone_note']).to include('Europe/Istanbul', 'ahead of your America/New_York')
    expect(home).not_to have_key('timezone_note')
    expect(bare).not_to have_key('timezone_note')
    expect(away.except('timezone_note')).to eq(bare)
  end
end
