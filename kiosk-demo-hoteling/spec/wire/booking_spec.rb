# frozen_string_literal: true

require "wire_helper"

RSpec.describe "booking a room", :wire do
  it "reserves, pays, and hands back the confirmation code the hotel keeps" do
    guest   = register
    booking = reserve(guest)
    setup   = client.run(guest, name: "payment_setup")
    expect([setup.status, setup.body["status"]]).to eq([200, "ready"])
    expect(pay(guest, booking).status).to eq(200)

    confirmed = confirm(guest, booking)
    expect(confirmed.status).to eq(200)
    code = confirmed.body["confirmation_code"]
    expect(code).to be_present

    listed = client.query(guest, name: "my_bookings").body.find { _1["booking_id"] == booking["booking_id"] }
    expect(listed["confirmation_code"]).to eq(code)
    expect(Booking.find(booking["booking_id"])).to have_attributes(status: "confirmed", confirmation_code: code)
    expect(Kiosk::Settlement.where(user_id: guest.user_id).count).to eq(1)
    expect(RoomHold.where(resource_kind: RoomHold::RESOURCE_KIND, resource_id: booking["booking_id"]).count).to eq(1)
  end

  it "does not confirm a booking nobody paid for" do
    guest   = register
    booking = reserve(guest)
    setup   = client.run(guest, name: "payment_setup")
    expect([setup.status, setup.body["status"]]).to eq([200, "ready"])

    refused = confirm(guest, booking)
    expect([refused.status, refused.body["detail"]]).to eq([403, "no settlement for this booking"])
  end
end
