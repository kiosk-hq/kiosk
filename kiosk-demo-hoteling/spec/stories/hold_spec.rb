# frozen_string_literal: true

require 'story_helper'

RSpec.describe 'A hold nobody pays for', type: :story do
  it 'an unpaid hold past its pay-by time frees the room for another guest, and its owner can no longer pay' do
    ada = a_guest
    ben = a_guest
    stay = { check_in: Date.current + 40, check_out: Date.current + 42 }
    held = ada.reserves(**stay)
    expect(held).to be_ok, held.to_s
    room = Booking.find(held['booking_id']).room_type

    expect(ben.rooms_free(at: room.property_id, **stay).rows.pluck('room_type_id')).not_to include(room.id)

    Booking.where(id: held['booking_id']).update_all(created_at: 16.minutes.ago)

    expect(ben.rooms_free(at: room.property_id, **stay).rows.pluck('room_type_id')).to include(room.id)
    taken = ben.does(:reserve_room, room_type_id: room.id, check_in: stay[:check_in].iso8601,
                                    check_out: stay[:check_out].iso8601)
    expect(taken).to be_ok, taken.to_s

    expect(ada.bookings.find { it['booking_id'] == held['booking_id'] }).to include('status' => 'cancelled',
                                                                                    'payment_state' => 'unpaid')
    late = ada.pays_for(held)
    expect(late).to be_refused(:forbidden)
    expect(late.detail).to include('pay-by time passed')
    expect(Booking.find(held['booking_id'])).to be_unpaid
    expect(ada.confirms(held).detail).to eq('this hold lapsed unpaid and the room was released')
  end
end
