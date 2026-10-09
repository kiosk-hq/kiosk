# frozen_string_literal: true

require "wire_helper"

RSpec.describe "browsing the catalogue", :wire do
  it "prices depth instead of refusing it, and tolls every hold" do
    guest = register
    curve = Array.new(7) do
      answer = client.query(guest, name: "properties")
      expect(answer.status).to eq(200)
      answer.proofs
    end
    expect(curve).to start_with(0).and include(be_positive)
    expect(curve).to eq(curve.sort)

    stay    = bookable_room(guest, check_in: Date.current + 30, check_out: Date.current + 33)
    booking = client.run(guest, name: "reserve_room", **stay)
    expect(booking).to have_attributes(status: 200, pow_retried: true)
    expect(booking.body["booking_id"]).to be_present
  end
end
