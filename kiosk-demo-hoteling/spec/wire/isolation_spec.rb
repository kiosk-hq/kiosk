# frozen_string_literal: true

require "wire_helper"

RSpec.describe "one guest's bookings", :wire do
  it "cannot be paid for, confirmed, or seen by another guest" do
    alice   = register
    bob     = register
    alices  = reserve(alice)

    paid = pay(bob, alices)
    expect([paid.status, paid.body["code"]]).to eq([403, "forbidden"])

    expect(pay(alice, alices).status).to eq(200)
    confirmed = confirm(bob, alices)
    expect([confirmed.status, confirmed.body["detail"]]).to eq([403, "booking not found or not yours"])

    bobs_id = reserve(bob, check_in: Date.current + 60)["booking_id"]
    expect(client.query(bob, name: "my_bookings").body.map { _1["booking_id"] }).to eq([bobs_id])
    expect(Booking.find(bobs_id).user_id).to eq(bob.user_id)
  end

  it "takes the principal from the token, never from an argument" do
    alice = register
    bob   = register

    stay   = bookable_room(bob, check_in: Date.current + 60, check_out: Date.current + 63)
    forged = client.run(bob, name: "reserve_room", **stay, user_id: alice.user_id)
    expect([forged.status, forged.body["code"]]).to eq([400, "bad_request"])
    expect(forged.body["detail"]).to include("user_id")
  end
end
