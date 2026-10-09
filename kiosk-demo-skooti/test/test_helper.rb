# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["KIOSK_TEST_AUTOCARD"] = "1"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/story_test"
require "kiosk/test_helpers/stripe_mock"
require_relative "../script/dev_unlock_key"
require_relative "../script/lock_sim"

# A rider's AI assistant: finds a vehicle nearby, reserves it, pays for the
# first minute and rides — a motorcycle only with a licence on record.
class Rider < Kiosk::TestHelpers::Customer
  def vehicles_nearby = asks(:scooters_available).rows
  def reservations = asks(:my_reservations).rows
  def reserves(vehicle, **extra) = does(:reserve, scooter_code: vehicle, **extra)
  def sets_up_payment = does(:payment_setup)
  def rides(reservation) = does(:start_rental, reservation_id: reservation["reservation_id"])
  def rides_motorcycle(reservation) = does(:rent_motorcycle, reservation_id: reservation["reservation_id"])

  # Signs a cart for the quoted upfront minute of `reservation`.
  def pays_for(reservation)
    now   = Time.now.to_i
    price = reservation["price_per_min_cents"]
    mandate = { user_id: principal.user_id, agent_id: principal.agent_id, iss: origin, currency: "eur",
                iat: now, exp: now + 600 }
    intent = mandate.merge(id: SecureRandom.uuid, scope: "mobility", cap_amount_cents: price)
    pays(intent:, cart: mandate.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: price,
                                      line_items: [{ qty: 1, price_cents: price,
                                                     reservation_id: reservation["reservation_id"] }]))
  end
end

class StoryTest < Kiosk::StoryTest
  setup { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }

  def a_rider = a_customer(as: Rider)

  # The lock on `vehicle`, which checks a rental token offline.
  def the_lock_on(vehicle) = LockSim.new(scooter_code: vehicle, skooti_public_key: OpenSSL::PKey.read(DevUnlockKey.public_key_pem))
end
