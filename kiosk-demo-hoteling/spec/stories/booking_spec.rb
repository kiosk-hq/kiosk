# frozen_string_literal: true

require 'story_helper'

RSpec.describe 'Booking a room', type: :story do
  it 'a guest with no account books three nights, pays, and gets the confirmation code the hotel keeps' do
    guest = a_guest
    booking = guest.reserves(check_in: Date.current + 30, check_out: Date.current + 33)
    expect(booking).to be_ok, booking.to_s
    expect(guest.sets_up_payment.rows).to include('status' => 'setup_required', 'setup_url' => be_present)
    expect(guest.sets_up_payment['status']).to eq('ready')
    expect(guest.pays_for(booking)).to be_ok

    row = guest.bookings.find { it['booking_id'] == booking['booking_id'] }
    expect(row).to include('status' => 'confirmed', 'payment_state' => 'paid', 'total_cents' => booking['total_cents'])
    code = row['confirmation_code']
    expect(code).to be_present

    expect(Booking.find(booking['booking_id'])).to have_attributes(status: 'confirmed', confirmation_code: code)
    expect(Kiosk::Settlement.where(user_id: guest.principal.user_id).count).to eq(1)
  end

  it 'a booking nobody paid for is not confirmed' do
    guest = a_guest
    booking = guest.reserves
    expect(guest.sets_up_payment['status']).to eq('setup_required')
    expect(guest.sets_up_payment['status']).to eq('ready')

    expect(guest.bookings.find { it['booking_id'] == booking['booking_id'] })
      .to include('status' => 'reserved', 'payment_state' => 'unpaid', 'confirmation_code' => nil)
  end
end
