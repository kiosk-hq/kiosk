# frozen_string_literal: true

require "spec_helper"
require "kiosk/test_helpers/live_server"
require "kiosk/redteam"
require "kiosk/redteam/stripe_mock"
require "kiosk/pow/equihash/solver"

# Drives this origin over HTTP as an assistant does.
module WireHelpers
  def client = @client ||= Kiosk::Redteam::Client.new(base_url: live_url)

  def register = client.register!(name: "guest")

  def bookable_room(guest, check_in:, check_out:)
    client.query(guest, name: "properties").body.each do |property|
      stay  = { property_id: property["property_id"], check_in: check_in.iso8601, check_out: check_out.iso8601 }
      rooms = client.query(guest, name: "availability", **stay).body
      return stay.merge(room_type_id: rooms.first["room_type_id"]) if rooms.any?
    end
    raise "no room is free for #{check_in}..#{check_out}"
  end

  def reserve(guest, check_in: Date.current + 30, check_out: check_in + 3)
    booking = client.run(guest, name: "reserve_room", **bookable_room(guest, check_in:, check_out:))
    expect(booking.status).to eq(200), booking.body.inspect
    booking.body
  end

  def pay(guest, booking, currency: "eur")
    now   = Time.now.to_i
    total = booking.fetch("total_cents")
    mandate = { user_id: guest.user_id, agent_id: guest.agent_id, iss: live_url, currency:, iat: now, exp: now + 600 }
    intent = mandate.merge(id: SecureRandom.uuid, scope: "lodging", cap_amount_cents: total)
    cart   = mandate.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: total,
                           line_items: [{ qty: booking.fetch("nights"), price_cents: booking.fetch("nightly_price_cents"),
                                          booking_id: booking.fetch("booking_id") }])
    client.pay(guest, intent:, cart:)
  end

  def confirm(guest, booking) = client.run(guest, name: "confirm_booking", booking_id: booking.fetch("booking_id"))

  # A query read with its headers, its toll paid: the answer and the proofs it cost.
  def tolled_get(guest, path, **params)
    wire   = Kiosk::Redteam::Wire.new(base_url: live_url)
    answer = wire.get(path, params, wire.bearer(guest.token))
    return [answer, 0] unless answer.status == 402

    proofs = answer.body.fetch("challenges").map { { challenge: _1, nonce: Kiosk::Pow::Equihash.solve(_1) } }
    [wire.get(path, params, wire.bearer(guest.token).merge("Kiosk-PoW" => JSON.generate(proofs))), proofs.size]
  end
end

RSpec.configure do |config|
  config.include Kiosk::TestHelpers::LiveServer, :wire
  config.include WireHelpers, :wire
  config.before(:each, :wire) { Stripe.api_base = Kiosk::Redteam::StripeMock.start }
end
