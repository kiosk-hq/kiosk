# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/story_test"

# A diner's AI assistant: looks for an open table, books it, reads the
# diner's bookings back and cancels one.
class Diner < Kiosk::TestHelpers::Customer
  def open_tables(party: 2, **filters) = asks(:availability, party_size: party, **filters).rows

  def books(table = open_tables.first, party: 2, **extra)
    does(:book_table, party_size: party, restaurant_id: table["restaurant_id"],
                      restaurant_table_id: table["restaurant_table_id"],
                      date: table["seating_date"], time: table["seating_time"], **extra)
  end

  def cancels(booking) = does(:cancel_booking, booking_id: booking["booking_id"])
  def bookings = asks(:my_bookings).rows.pluck("booking_id")
end

# Searching for a table is free unless a story turns the toll on;
# registering is tolled as shipped.
class StoryTest < Kiosk::StoryTest
  SHIPPED_TOLL = Kiosk.configuration.reputation_policy

  setup { toll(nil) }
  teardown { toll(SHIPPED_TOLL) }

  def toll(policy) = Kiosk.configuration.reputation_policy = policy

  def a_diner = a_customer(as: Diner)
end
