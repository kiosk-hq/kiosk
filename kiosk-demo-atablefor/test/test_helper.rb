# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/test_helpers/live_server"
require "kiosk/redteam"

# Drives this origin over HTTP as an assistant does. The query toll is off
# unless a test turns it on; registration is tolled as shipped.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  SHIPPED_TOLL = Kiosk.configuration.reputation_policy

  setup { toll(nil) }
  teardown { toll(SHIPPED_TOLL) }

  def toll(policy) = Kiosk.configuration.reputation_policy = policy

  def client = @client ||= Kiosk::Redteam::Client.new(base_url: live_url)

  def wire = @wire ||= Kiosk::Redteam::Wire.new(base_url: live_url)

  def register = client.register!(name: "diner")

  def open_tables(diner) = client.query(diner, name: "availability", party_size: 2).body

  def book(diner, table = open_tables(diner).first)
    client.run(diner, name: "book_table", party_size: 2,
                      **table.slice("restaurant_id", "restaurant_table_id").symbolize_keys,
                      date: table["seating_date"], time: table["seating_time"])
  end

  def my_booking_ids(diner) = client.query(diner, name: "my_bookings").body.map { _1["booking_id"] }
end
