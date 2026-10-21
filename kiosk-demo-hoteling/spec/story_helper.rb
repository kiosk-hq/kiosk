# frozen_string_literal: true

require 'spec_helper'
require 'kiosk/story_spec'
require 'kiosk/test_helpers/stripe_mock'

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

  # `currency:` spells the checkout's currency another way in the payment mandate.
  def pays_for(booking, currency: nil)
    return pays(booking['checkout_jwt']) if currency.nil?

    Kiosk::TestHelpers::Answer.new(@assistant.pay_raw(principal, **respelled(booking['checkout_jwt'], currency)))
  end

  # The two mandates for `checkout_jwt`, the payment one signed again with `currency`.
  def respelled(checkout_jwt, currency)
    mandates = Kiosk::TestHelpers::Mandate.pay(principal.rsa_key, checkout_jwt)
    payment = Kiosk::TestHelpers::Mandate.content(mandates[:payment])
    payment['payment_amount']['currency'] = currency
    mandates.merge(payment: Kiosk::TestHelpers::Mandate.sign(principal.rsa_key, payment))
  end

  def a_free_room(check_in:, check_out:)
    browses_hotels.rows.each do |hotel|
      rooms = rooms_free(at: hotel['property_id'], check_in:, check_out:).rows
      if rooms.any?
        return { room_type_id: rooms.first['room_type_id'], check_in: check_in.iso8601,
                 check_out: check_out.iso8601 }
      end
    end
    raise "no room is free for #{check_in}..#{check_out}"
  end
end

module HotelStory
  def a_guest = a_customer(as: Guest)
end

RSpec.configure do |config|
  config.include HotelStory, type: :story
  config.before(:each, type: :story) { Kiosk::TestHelpers::StripeMock.start }
end
