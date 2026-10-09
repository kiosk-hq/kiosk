# frozen_string_literal: true

require "story_helper"

RSpec.describe "Booking a room", type: :story do
  it "a guest with no account books three nights, pays, and gets the confirmation code the hotel keeps" do
    guest = a_guest
    booking = guest.reserves(check_in: Date.current + 30, check_out: Date.current + 33)
    expect(booking).to be_ok, booking.to_s
    expect(guest.sets_up_payment["status"]).to eq("ready")
    expect(guest.pays_for(booking)).to be_ok

    confirmed = guest.confirms(booking)
    expect(confirmed).to be_ok, confirmed.to_s
    code = confirmed["confirmation_code"]
    expect(code).to be_present
    expect(guest.bookings.find { _1["booking_id"] == booking["booking_id"] }["confirmation_code"]).to eq(code)

    expect(Booking.find(booking["booking_id"])).to have_attributes(status: "confirmed", confirmation_code: code)
    expect(Kiosk::Settlement.where(user_id: guest.principal.user_id).count).to eq(1)
    expect(RoomHold.where(resource_kind: RoomHold::RESOURCE_KIND, resource_id: booking["booking_id"]).count).to eq(1)
  end

  it "a booking nobody paid for is not confirmed" do
    guest = a_guest
    booking = guest.reserves
    expect(guest.sets_up_payment["status"]).to eq("ready")

    unpaid = guest.confirms(booking)
    expect(unpaid).to be_refused(:forbidden)
    expect(unpaid["detail"]).to eq("no settlement for this booking")
  end
end
