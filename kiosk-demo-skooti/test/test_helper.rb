# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require_relative '../config/environment'
require 'kiosk/test_helpers/small_equihash'
require 'rails/test_help'
require 'kiosk/story_test'
require 'kiosk/test_helpers/stripe_mock'
require_relative '../script/lock_sim'

# A rider's AI assistant: finds a vehicle nearby, reserves it, pays for the
# first minute and rides — a motorcycle only with a licence on record.
class Rider < Kiosk::TestHelpers::Customer
  def vehicles_nearby = asks(:scooters_available).rows
  def reservations = asks(:my_reservations).rows
  def reserves(vehicle, **extra) = does(:reserve, scooter_code: vehicle, **extra)
  def rides(reservation) = does(:start_rental, reservation_id: reservation['reservation_id'])
  def rides_motorcycle(reservation) = does(:rent_motorcycle, reservation_id: reservation['reservation_id'])

  def pays_for(reservation) = pays_cart(reservation['cart'], scope: 'mobility')
end

class StoryTest < Kiosk::StoryTest
  setup { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }

  def a_rider = a_customer(as: Rider)

  DEV_UNLOCK_PUBLIC_KEY = OpenSSL::PKey.read(OpenSSL::PKey.read(Rails.root.join('config/dev_unlock_key.pem').read).public_to_pem)

  # The lock on `vehicle`, provisioned with the development key; it checks a rental token offline.
  def the_lock_on(vehicle) = LockSim.new(scooter_code: vehicle, skooti_public_key: DEV_UNLOCK_PUBLIC_KEY)
end
