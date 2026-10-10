# frozen_string_literal: true

require "test_helper"

class TableSearchTest < ActiveSupport::TestCase
  setup do
    Restaurant.create!(name: "Tasca", neighborhood: "Alfama", timezone: "Europe/Lisbon")
    Restaurant.create!(name: "Adega", neighborhood: "Graça", timezone: "Europe/Lisbon")
  end

  def errors(**filters) = TableSearch.new(party_size: 2, **filters).tap(&:validate).errors.full_messages

  test "a neighbourhood filter is one the aggregator serves, matched exactly" do
    assert_empty errors(neighborhood: "Alfama")
    assert_empty errors
    assert_equal ['neighborhood "alfama" is not one this aggregator serves — currently Alfama, Graça'],
                 errors(neighborhood: "alfama")
  end

  test "a date filter names the upcoming days, once each" do
    lisbon = Time.find_zone!("Europe/Lisbon")

    travel_to lisbon.local(2026, 9, 1, 19, 30) do
      assert_empty errors(date: "2026-09-02")
      assert_equal ['date "2026-09-03" is not among the upcoming seatings — currently 2026-09-01, 2026-09-02'],
                   errors(date: "2026-09-03")
    end
  end

  test "the seatings are the restaurant's upcoming ones on the requested date and time" do
    restaurant = Restaurant.new(timezone: "Europe/Lisbon")

    travel_to Time.find_zone!("Europe/Lisbon").local(2026, 9, 1, 12) do
      seatings = TableSearch.new(date: "2026-09-02", time: "20:00").seatings(restaurant)
      assert_equal ["2026-09-02T20:00:00+01:00"], seatings.map(&:iso8601)
      assert_equal 6, TableSearch.new.seatings(restaurant).size
    end
  end
end
