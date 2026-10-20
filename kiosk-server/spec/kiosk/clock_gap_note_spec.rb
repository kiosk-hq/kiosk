# frozen_string_literal: true

require 'active_support/testing/time_helpers'

RSpec.describe Kiosk, '.clock_gap_note' do
  include ActiveSupport::Testing::TimeHelpers

  def zone(name) = Time.find_zone!(name)

  # The note at a winter instant, when London is on GMT and New York on EST.
  def note(place_zone, caller_zone, at: Time.utc(2026, 1, 15, 12))
    travel_to(at) { described_class.clock_gap_note('Pera House', zone(place_zone), caller_zone && zone(caller_zone)) }
  end

  it 'says how many hours the place is ahead of the caller' do
    expect(note('Europe/Istanbul', 'America/New_York'))
      .to eq('Pera House runs on Europe/Istanbul time, 8 hours ahead of your America/New_York.')
  end

  it 'says how many hours the place is behind the caller' do
    expect(note('America/New_York', 'Europe/Istanbul'))
      .to eq('Pera House runs on America/New_York time, 8 hours behind your Europe/Istanbul.')
  end

  it 'counts a half-hour gap and a single hour' do
    expect(note('Europe/Istanbul', 'Asia/Kolkata')).to include('2.5 hours behind your Asia/Kolkata')
    expect(note('Europe/Lisbon', 'Europe/Paris')).to include('1 hour behind your Europe/Paris')
  end

  it 'says nothing to a caller on the same clock now, or one that declared none' do
    expect(note('Europe/Istanbul', 'Asia/Riyadh')).to be_nil
    expect(note('Europe/Istanbul', nil)).to be_nil
  end

  it 'reads the gap on both clocks now, so a summer-time change moves it' do
    expect(note('Europe/London', 'America/New_York')).to include('5 hours ahead')
    expect(note('Europe/London', 'America/New_York', at: Time.utc(2026, 3, 15, 12))).to include('4 hours ahead')
  end
end
