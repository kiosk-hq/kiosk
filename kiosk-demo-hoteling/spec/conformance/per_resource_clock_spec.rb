# frozen_string_literal: true

require "spec_helper"
require "active_support/testing/time_helpers"

# ── THE CLOCK IS THE PROPERTY'S, AND THIS IS THE ONLY THING THAT PROVES IT ───
#
# The rule: an answer is rendered at the place the service happens, and that
# zone is a property of the SERVICED RESOURCE — never one constant configured on
# the operator, because one operator may run stores in many time zones and
# locations.
#
# THE FLEET CANNOT FAIL THIS RULE ON ITS OWN, WHICH IS WHY THIS FILE EXISTS.
# hoteling seeds 100 properties and every one of them is in Istanbul, so a
# per-property zone and a single origin constant produce byte-identical answers
# on every call the seeded demo can make. A rule no gate can fail is not a rule.
# So the two zones are a FIXTURE rather than a seed: seeding this demo into a
# second city is product scope and is deliberately not part of this change, and
# it is not needed — what has to be proved is where the zone is READ FROM, and
# two rows are enough for that.
#
# WHAT WOULD GO RED. Point `WireArguments.past_stay`'s zone back at the origin
# constant — `zone: WireArguments.default_zone`, or drop the parameter — and the
# two properties stop disagreeing, because there is only one clock again. Every
# other gate in this demo stays green while that is true.
RSpec.describe "a property's clock is the property's" do
  include ActiveSupport::Testing::TimeHelpers

  # 12:00 UTC on the 15th is 15:00 on the 15th in Istanbul and 01:00 on the
  # SIXTEENTH in Auckland. One instant, two calendar days, and the two
  # properties belong to ONE operator.
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

  it "reads each property's zone off the property, not off this origin" do
    expect(WireArguments.zone_for(istanbul.id).name).to eq("Europe/Istanbul")
    expect(WireArguments.zone_for(auckland.id).name).to eq("Pacific/Auckland")
    expect(WireArguments.zone_for(istanbul.id).name).not_to eq(WireArguments.zone_for(auckland.id).name)
  end

  it "gives Property#zone the column's value, resolved through tzinfo" do
    expect(auckland.zone).to be_a(ActiveSupport::TimeZone)
    expect(auckland.zone.tzinfo.identifier).to eq("Pacific/Auckland")
  end

  # THE GATE. One operator, one date, two answers — because at this instant one
  # of the two properties is already on tomorrow.
  it "sells the 15th at one property and refuses it as past at the other, at the same instant" do
    travel_to(instant) do
      expect(WireArguments.past_stay(the_15th, zone: WireArguments.zone_for(istanbul.id))).to be_nil

      refusal = WireArguments.past_stay(the_15th, zone: WireArguments.zone_for(auckland.id))
      expect(refusal).not_to be_nil
      expect(refusal.code).to eq("bad_request")
      expect(refusal.message).to include("is in the past")
      # The refusal NAMES the clock it judged on, so a caller is never left
      # guessing whose midnight decided (spec §3 point 8).
      expect(refusal.message).to include("Pacific/Auckland")
      expect(refusal.message).not_to include("Europe/Istanbul")
    end
  end

  # THE CONTROL, and without it the example above proves only that a parameter
  # is a parameter: read off the ORIGIN, both properties answer the Istanbul
  # way, so one of the two answers above is wrong and nothing says which.
  it "answers BOTH properties the same way when the zone is read off the origin — the wrong source" do
    travel_to(instant) do
      expect(WireArguments.past_stay(the_15th, zone: WireArguments.default_zone)).to be_nil
      expect(WireArguments.default_zone.name).to eq("Europe/Istanbul")
    end
  end

  # The row says which clock it is on (spec §3 point 8 rule 9), and it says a
  # DIFFERENT thing for the two properties of the same operator — which is the
  # whole of ruling 1, visible on the wire rather than only in a guard.
  it "publishes each property's own zone in its hotel_detail row" do
    ist = kiosk_origin.call(:hotel_detail, kind: :query,
                            params: { property_id: istanbul.id }, as: guest.id).first
    akl = kiosk_origin.call(:hotel_detail, kind: :query,
                            params: { property_id: auckland.id }, as: guest.id).first

    expect(ist[:timezone] || ist["timezone"]).to eq("Europe/Istanbul")
    expect(akl[:timezone] || akl["timezone"]).to eq("Pacific/Auckland")
  end

  # A calendar day is NEVER converted (spec §3 point 8 rule 6): `check_in`
  # echoes back byte-identical however far the caller's own clock is from the
  # property's. A room-night is a day at the hotel, and an offset attached to
  # one is an invitation to sell the night before.
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
