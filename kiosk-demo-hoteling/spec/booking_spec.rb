# frozen_string_literal: true

require 'spec_helper'

RSpec.shared_context 'a booking on the first of September in Istanbul' do
  include ActiveSupport::Testing::TimeHelpers

  let(:property)  { Property.create!(name: 'Booking Spec', city: 'Istanbul', timezone: 'Europe/Istanbul', stars: 4, amenities: []) }
  let(:room_type) { RoomType.create!(property:, name: 'Double', nightly_price_cents: 18_000) }
  let(:guest)     { User.create!(email: 'booking-spec@example.test', password: 'booking-spec-password') }

  def errors(check_in: '2026-09-01', check_out: '2026-09-04', **attributes)
    booking = described_class.new(user: guest, room_type:, total_cents: 0,
                                  check_in: Date.iso8601(check_in), check_out: Date.iso8601(check_out), **attributes)
    booking.tap(&:validate).errors.full_messages
  end

  before { travel_to(Time.find_zone!('Europe/Istanbul').local(2026, 9, 1, 12)) }
end

RSpec.describe Booking, 'stay dates', type: :model do
  include_context 'a booking on the first of September in Istanbul'

  it 'holds the checkout after the first night' do
    expect(errors).to be_empty
    expect(errors(check_out: '2026-09-01')).to eq(['check_out must be after check_in'])
  end

  it "sells tonight and refuses yesterday on the property's clock, naming the floor and the zone" do
    expect(errors(check_in: '2026-08-31').sole)
      .to start_with('check_in 2026-08-31 is in the past — the earliest night this hotel sells is ' \
                     '2026-09-01 (Europe/Istanbul)')
  end

  it 'holds at most MAX_NIGHTS nights, so a total always fits' do
    expect(errors(check_out: (Date.new(2026, 9, 1) + Booking::MAX_NIGHTS).iso8601)).to be_empty
    expect(errors(check_out: (Date.new(2026, 9, 1) + Booking::MAX_NIGHTS + 1).iso8601))
      .to eq(['check_out is 31 nights after check_in; one reservation holds at most 30'])
    expect(Booking::MAX_NIGHTS * RoomType::MAX_NIGHTLY_PRICE_CENTS).to be <= 2_147_483_647
  end
end

RSpec.describe Booking, 'room type', type: :model do
  include_context 'a booking on the first of September in Istanbul'

  it 'books the hotel its room type belongs to' do
    elsewhere = RoomType.create!(property: Property.create!(name: 'Elsewhere', city: 'Istanbul', stars: 3, amenities: []),
                                 name: 'Single', nightly_price_cents: 9_000)
    booking = described_class.new(user: guest, property:, room_type: elsewhere,
                                  check_in: Date.new(2026, 9, 1), check_out: Date.new(2026, 9, 2))

    expect(booking.tap(&:validate).property).to eq(elsewhere.property)
    expect(errors(room_type: nil)).to eq(['room_type_id is not a room type here — call availability for the free ones'])
  end
end
