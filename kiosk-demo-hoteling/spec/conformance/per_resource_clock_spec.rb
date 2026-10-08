# frozen_string_literal: true

require "spec_helper"

# Every seeded hotel is in Istanbul, so two fixtures in two zones are what show
# the clock is read off the property rather than off the origin.
RSpec.describe "a property's clock is the property's" do
  include ActiveSupport::Testing::TimeHelpers

  # 15:00 on the 15th in Istanbul, 01:00 on the 16th in Auckland.
  let(:instant)  { Time.utc(2026, 3, 15, 12, 0, 0) }
  let(:the_15th) { Date.new(2026, 3, 15) }

  let(:istanbul) do
    Property.create!(name: "Bosphorus Conformance", city: "Istanbul", timezone: "Europe/Istanbul",
                     neighbourhood: "Beşiktaş", stars: 4, amenities: [], address: "1 Barbaros Blv")
  end

  let(:auckland) do
    Property.create!(name: "Harbour Conformance", city: "Auckland", timezone: "Pacific/Auckland",
                     neighbourhood: nil, stars: 4, amenities: [], address: "1 Quay St")
  end

  let(:guest) { User.create!(email: "clock-conformance@example.test", password: "conformance-fixture") }

  before do
    RoomType.create!(property: istanbul, name: "Double", nightly_price_cents: 18_000)
    RoomType.create!(property: auckland, name: "Double", nightly_price_cents: 21_000)
  end

  it "reads each property's zone off the property" do
    expect(WireArguments.zone_for(istanbul.id).name).to eq("Europe/Istanbul")
    expect(WireArguments.zone_for(auckland.id).name).to eq("Pacific/Auckland")
    expect(auckland.zone.tzinfo.identifier).to eq("Pacific/Auckland")
  end

  it "sells the 15th at one property and refuses it as past at the other, at the same instant" do
    travel_to(instant) do
      expect(WireArguments.bookable!(the_15th, zone: WireArguments.zone_for(istanbul.id))).to be_nil

      expect { WireArguments.bookable!(the_15th, zone: WireArguments.zone_for(auckland.id)) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /is in the past.*Pacific\/Auckland/)
    end
  end

  it "publishes each property's own zone in its hotel_detail row" do
    ist = kiosk_origin.call(:hotel_detail, kind: :query,
                            params: { property_id: istanbul.id }, as: guest.id).first
    akl = kiosk_origin.call(:hotel_detail, kind: :query,
                            params: { property_id: auckland.id }, as: guest.id).first

    expect(ist[:timezone] || ist["timezone"]).to eq("Europe/Istanbul")
    expect(akl[:timezone] || akl["timezone"]).to eq("Pacific/Auckland")
  end

  it "echoes a calendar day back byte-identical" do
    row = kiosk_origin.call(:hotel_detail, kind: :query,
                            params: { property_id: auckland.id,
                                      check_in:  (Date.current + 40).iso8601,
                                      check_out: (Date.current + 43).iso8601 },
                            as: guest.id).first

    expect(row[:check_in] || row["check_in"]).to eq((Date.current + 40).iso8601)
    expect(row[:check_out] || row["check_out"]).to eq((Date.current + 43).iso8601)
  end
end
