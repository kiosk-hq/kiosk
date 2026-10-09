# frozen_string_literal: true

require "spec_helper"
require "kiosk/test_helpers/live_server"
require "kiosk/test_helpers/stripe_mock"

# Drives this origin over HTTP as an assistant does.
module WireHelpers

  def bookable_room(guest, check_in:, check_out:)
    assistant.query(guest, name: "properties").body.each do |property|
      stay  = { property_id: property["property_id"], check_in: check_in.iso8601, check_out: check_out.iso8601 }
      rooms = assistant.query(guest, name: "availability", **stay).body
      return stay.merge(room_type_id: rooms.first["room_type_id"]) if rooms.any?
    end
    raise "no room is free for #{check_in}..#{check_out}"
  end

  def reserve(guest, check_in: Date.current + 30, check_out: check_in + 3)
    booking = assistant.run(guest, name: "reserve_room", **bookable_room(guest, check_in:, check_out:))
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
    assistant.pay(guest, intent:, cart:)
  end

  def confirm(guest, booking) = assistant.run(guest, name: "confirm_booking", booking_id: booking.fetch("booking_id"))
end

RSpec.configure do |config|
  config.include Kiosk::TestHelpers::LiveServer, :wire
  config.include WireHelpers, :wire
  config.before(:each, :wire) { Stripe.api_base = Kiosk::TestHelpers::StripeMock.start }
end
