# frozen_string_literal: true

require "spec_helper"
require "kiosk/story_spec"
require "kiosk/test_helpers/stripe_mock"

# A guest's AI assistant: searches the hotels, reserves a room, pays for it and
# asks for the confirmation code the hotel minted.
class Guest < Kiosk::TestHelpers::Customer
  def browses_hotels = asks(:properties)
  def searches(**filters) = asks(:search_hotels, **filters)
  def turns_to(page) = searches(**URI.decode_www_form(URI(page).query).to_h.symbolize_keys)
  def looks_at(hotel) = asks(:hotel_detail, property_id: hotel)
  def bookings = asks(:my_bookings).rows

  def rooms_free(at:, check_in:, check_out:)
    asks(:availability, property_id: at, check_in: check_in.iso8601, check_out: check_out.iso8601)
  end

  def reserves(check_in: Date.current + 30, check_out: check_in + 3, **extra)
    does(:reserve_room, **a_free_room(check_in:, check_out:), **extra)
  end

  # Signs a cart for every night of the booking at its nightly price.
  def pays_for(booking, currency: "eur")
    pays(total: booking["total_cents"], scope: "lodging", currency:,
         line_items: [{ qty: booking["nights"], price_cents: booking["nightly_price_cents"], booking_id: booking["booking_id"] }])
  end

  def confirms(booking) = does(:confirm_booking, booking_id: booking["booking_id"])

  def a_free_room(check_in:, check_out:)
    browses_hotels.rows.each do |hotel|
      rooms = rooms_free(at: hotel["property_id"], check_in:, check_out:).rows
      return { property_id: hotel["property_id"], room_type_id: rooms.first["room_type_id"],
               check_in: check_in.iso8601, check_out: check_out.iso8601 } if rooms.any?
    end
    raise "no room is free for #{check_in}..#{check_out}"
  end
end

module HotelStory
  def a_guest = a_customer(as: Guest)
end

RSpec.configure do |config|
  config.include HotelStory, type: :story
  config.before(:each, type: :story) { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }
end
