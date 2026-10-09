# frozen_string_literal: true

require "story_helper"

RSpec.describe "The toll an assistant pays", type: :story do
  it "an assistant reading the hotel list over and over pays more each time instead of being turned away, and every hold is tolled" do
    guest = a_guest
    tolls = Array.new(7) { guest.browses_hotels.tap { expect(_1).to be_ok }.tolls_paid }
    expect(tolls).to start_with(0).and include(be_positive)
    expect(tolls).to eq(tolls.sort)

    booking = guest.reserves
    expect(booking).to be_ok, booking.to_s
    expect(booking.tolls_paid).to be_positive
  end
end
