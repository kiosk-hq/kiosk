# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Property, '#timezone_note' do
  include ActiveSupport::Testing::TimeHelpers

  let(:hotel) { Property.new(name: 'Bosphorus Palace', timezone: 'Europe/Istanbul') }

  it 'names the hours between the two clocks, in one sentence' do
    travel_to(Time.utc(2026, 1, 15, 12)) do
      expect(hotel.timezone_note(Time.find_zone!('Europe/Lisbon')))
        .to eq('Bosphorus Palace runs on Europe/Istanbul time, 3 hours ahead of your Europe/Lisbon. ' \
               "Every date and time here is the hotel's.")
      expect(hotel.timezone_note(Time.find_zone!('Asia/Kolkata'))).to include('2.5 hours behind your Asia/Kolkata')
    end
  end

  it 'says nothing to a caller on the same clock, or one that declared none' do
    expect(hotel.timezone_note(Time.find_zone!('Asia/Riyadh'))).to be_nil
    expect(hotel.timezone_note(nil)).to be_nil
  end
end
