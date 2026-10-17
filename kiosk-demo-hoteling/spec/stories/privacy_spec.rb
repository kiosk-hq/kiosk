# frozen_string_literal: true

require 'story_helper'

RSpec.describe "One guest's bookings", type: :story do
  it 'another guest can neither pay for nor see them' do
    alice = a_guest
    bob = a_guest
    alices = alice.reserves

    expect(bob.pays_for(alices)).to be_refused(:forbidden)
    expect(alice.pays_for(alices)).to be_ok

    bobs = bob.reserves(check_in: Date.current + 60)
    expect(bob.bookings.pluck('booking_id')).to eq([bobs['booking_id']])
    expect(Booking.find(bobs['booking_id']).user_id).to eq(bob.principal.user_id)
  end

  it "a guest cannot book in another guest's name" do
    alice = a_guest
    bob = a_guest

    forged = bob.reserves(check_in: Date.current + 60, user_id: alice.principal.user_id)
    expect(forged).to be_refused(:bad_request)
    expect(forged['detail']).to include('user_id')
  end
end
