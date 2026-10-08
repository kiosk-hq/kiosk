# frozen_string_literal: true

require "test_helper"

class WireArgumentsTest < ActiveSupport::TestCase
  LISBON = Seatings.default_zone
  UPCOMING = [[Date.new(2026, 9, 1), "19:00"], [Date.new(2026, 9, 1), "20:00"], [Date.new(2026, 9, 2), "19:00"]].freeze

  def refusal(&) = assert_raises(Kiosk::Server::Errors::BadRequest, &)

  test "a seating is one of the three, not yet started, and inside the horizon" do
    travel_to LISBON.local(2026, 9, 1, 19, 30) do
      assert_equal LISBON.local(2026, 9, 1, 20), WireArguments.seating!("2026-09-01", "20:00", LISBON)
      assert_match(/unknown seating time: 18:00/, refusal { WireArguments.seating!("2026-09-01", "18:00", LISBON) }.message)
      assert_match(/has already started/, refusal { WireArguments.seating!("2026-09-01", "19:00", LISBON) }.message)
      assert_equal 'date "2026-09-05" is not among the upcoming seatings — currently 2026-09-01, 2026-09-02',
                   refusal { WireArguments.seating!("2026-09-05", "19:00", LISBON) }.message
    end
  end

  test "a date filter names the upcoming days, once each" do
    assert_nil WireArguments.seating_date!("2026-09-02", UPCOMING)
    assert_nil WireArguments.seating_date!(nil, UPCOMING)
    assert_equal 'date "2026-09-03" is not among the upcoming seatings — currently 2026-09-01, 2026-09-02',
                 refusal { WireArguments.seating_date!("2026-09-03", UPCOMING) }.message
    assert_match(/currently none\z/, refusal { WireArguments.seating_date!("2026-09-01", []) }.message)
  end

  test "a neighbourhood filter is one the aggregator serves, matched exactly" do
    served = ["Alfama", "Chiado"]
    assert_nil WireArguments.neighborhood!("Alfama", served)
    assert_nil WireArguments.neighborhood!(nil, served)
    assert_equal 'neighborhood "alfama" is not one this aggregator serves — currently Alfama, Chiado',
                 refusal { WireArguments.neighborhood!("alfama", served) }.message
    assert_match(/currently none\z/, refusal { WireArguments.neighborhood!("Alfama", []) }.message)
  end
end
