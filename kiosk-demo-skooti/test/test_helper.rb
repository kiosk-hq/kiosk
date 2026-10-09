# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["KIOSK_TEST_AUTOCARD"] = "1"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/test_helpers/live_server"
require "kiosk/test_helpers/assistant"
require "kiosk/test_helpers/stripe_mock"
require_relative "../script/dev_unlock_key"
require_relative "../script/lock_sim"

# Drives this origin over HTTP as an assistant does.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  setup { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }

  def client = @client ||= Kiosk::TestHelpers::Assistant.new(base_url: live_url)

  def register = client.register!

  def reserve(rider, scooter_code)
    reservation = client.run(rider, name: "reserve", scooter_code:)
    assert_equal 200, reservation.status, reservation.body
    reservation.body
  end

  def pay(rider, reservation)
    now   = Time.now.to_i
    price = reservation.fetch("price_per_min_cents")
    mandate = { user_id: rider.user_id, agent_id: rider.agent_id, iss: live_url, currency: "eur",
                iat: now, exp: now + 600 }
    intent = mandate.merge(id: SecureRandom.uuid, scope: "mobility", cap_amount_cents: price)
    cart   = mandate.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: price,
                           line_items: [{ qty: 1, price_cents: price, reservation_id: reservation.fetch("reservation_id") }])
    client.pay(rider, intent:, cart:)
  end

  def lock(scooter_code) = LockSim.new(scooter_code:, skooti_public_key: OpenSSL::PKey.read(DevUnlockKey.public_key_pem))
end
