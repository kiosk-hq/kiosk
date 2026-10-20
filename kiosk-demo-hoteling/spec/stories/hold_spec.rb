# frozen_string_literal: true

require 'story_helper'

RSpec.describe 'A hold', type: :story do
  describe 'nobody pays for' do
    it 'an unpaid hold past its pay-by time frees the room for another guest, and its owner can no longer pay' do
      ada = a_guest
      ben = a_guest
      stay = { check_in: Date.current + 40, check_out: Date.current + 42 }
      held = ada.reserves(**stay)
      expect(held).to be_ok, held.to_s
      room = Booking.find(held['booking_id']).room_type

      expect(ben.rooms_free(at: room.property_id, **stay).rows.pluck('room_type_id')).not_to include(room.id)

      Booking.find(held['booking_id']).update!(created_at: 16.minutes.ago)
      ada.listens_for(:booking_confirmation)

      expect(ben.rooms_free(at: room.property_id, **stay).rows.pluck('room_type_id')).to include(room.id)
      taken = ben.does(:reserve_room, room_type_id: room.id, check_in: stay[:check_in].iso8601,
                                      check_out: stay[:check_out].iso8601)
      expect(taken).to be_ok, taken.to_s

      expect(ada.hears(:booking_confirmation, about: held['booking_id']))
        .to eq('booking_id' => held['booking_id'], 'status' => 'cancelled', 'reason' => 'hold_lapsed')
      expect(ada.bookings.find { it['booking_id'] == held['booking_id'] }).to include('status' => 'cancelled',
                                                                                      'payment_state' => 'unpaid')
      late = ada.pays_for(held)
      expect(late).to be_refused(:forbidden)
      expect(late.detail).to include('pay-by time passed')
      expect(Booking.find(held['booking_id'])).to be_unpaid
    end

    describe 'at its pay-by time' do
      it 'is cancelled, and its owner is told once' do
        ada = a_guest
        held = ada.reserves
        ada.listens_for(:booking_confirmation)

        HoldLapseJob.perform_now(held['booking_id'])
        expect(Booking.find(held['booking_id'])).to be_reserved

        Booking.find(held['booking_id']).update!(created_at: 16.minutes.ago)
        2.times { HoldLapseJob.perform_now(held['booking_id']) }

        expect(ada.hears(:booking_confirmation, about: held['booking_id']))
          .to eq('booking_id' => held['booking_id'], 'status' => 'cancelled', 'reason' => 'hold_lapsed')
        expect(Booking.find(held['booking_id'])).to be_cancelled
        notices = "SELECT count(*) FROM kiosk.events WHERE subject = #{Booking.connection.quote(held['booking_id'])}"
        expect(Booking.connection.select_value(notices)).to eq(1)
      end
    end
  end

  describe 'paid for, at its pay-by time' do
    it 'is not cancelled' do
      ada = a_guest
      held = ada.reserves
      expect(ada.pays_for(held)).to be_ok

      Booking.find(held['booking_id']).update!(created_at: 16.minutes.ago)
      HoldLapseJob.perform_now(held['booking_id'])

      expect(Booking.find(held['booking_id'])).not_to be_cancelled
    end
  end
end
