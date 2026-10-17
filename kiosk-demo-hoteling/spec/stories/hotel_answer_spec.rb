# frozen_string_literal: true

require 'story_helper'

RSpec.shared_context 'a hotel that answers on demand' do
  before { Rails.configuration.x.hoteling.decision_delay_seconds = 1.hour }

  def the_hotel_answers(booking, accepts:)
    Rails.configuration.x.hoteling.decline_rate = accepts ? 0 : 1
    PropertyDecisionJob.perform_now(booking['booking_id'])
    Booking.find(booking['booking_id'])
  end
end

RSpec.describe "The hotel's answer to a paid booking", type: :story do
  include_context 'a hotel that answers on demand'

  it 'a guest waits for the hotel, and once it accepts reads the confirmation code, which a later answer does not change' do
    guest = a_guest
    booking = guest.reserves
    expect(guest.pays_for(booking)).to be_ok

    expect(guest.bookings.find { it['booking_id'] == booking['booking_id'] })
      .to include('status' => 'reserved', 'payment_state' => 'paid', 'confirmation_code' => nil)

    guest.listens_for(:booking_confirmation)
    code = the_hotel_answers(booking, accepts: true).confirmation_code
    expect(code).to be_present
    news = guest.hears(:booking_confirmation, about: booking['booking_id'])
    expect(news).to eq('booking_id' => booking['booking_id'], 'status' => 'confirmed', 'confirmation_code' => code)
    expect(guest.bookings.find { it['booking_id'] == booking['booking_id'] })
      .to include('status' => 'confirmed', 'confirmation_code' => code)

    expect(the_hotel_answers(booking, accepts: false)).to have_attributes(status: 'confirmed', confirmation_code: code)
  end
end

RSpec.describe 'A hotel that declines a booking', type: :story do
  include_context 'a hotel that answers on demand'

  it 'a hotel that declines cancels the booking, frees its nights and refunds the guest' do
    guest = a_guest
    booking = guest.reserves
    expect(guest.pays_for(booking)).to be_ok
    charge = Kiosk::Settlement.find_by!(user_id: guest.principal.user_id).psp_reference

    guest.listens_for(:booking_confirmation)
    declined = the_hotel_answers(booking, accepts: false)
    expect(declined).to have_attributes(status: 'cancelled', payment_status: 'refunded', payment_state: 'refunded')
    expect(declined.refund_psp_reference).to start_with('re_')
    expect(Booking.live.where(id: declined.id)).to be_empty
    news = guest.hears(:booking_confirmation, about: booking['booking_id'])
    expect(news).to eq('booking_id' => declined.id, 'status' => 'cancelled', 'reason' => 'property_declined',
                       'refund' => { 'amount_cents' => declined.total_cents, 'currency' => 'eur',
                                     'psp_reference' => declined.refund_psp_reference, 'reverses' => charge })
    expect(guest.bookings.find { it['booking_id'] == declined.id })
      .to include('status' => 'cancelled', 'payment_state' => 'refunded', 'confirmation_code' => nil)
  end
end

RSpec.describe 'A hotel that declines a booking', 'with no charge on record', type: :story do
  include_context 'a hotel that answers on demand'

  it 'a hotel that declines a booking with no charge on record refunds nothing' do
    guest = a_guest
    booking = guest.reserves
    Booking.find(booking['booking_id']).update!(payment_status: :paid)

    guest.listens_for(:booking_confirmation)
    expect(the_hotel_answers(booking, accepts: false)).to have_attributes(status: 'cancelled', refund_psp_reference: nil)
    news = guest.hears(:booking_confirmation, about: booking['booking_id'])
    expect(news).to eq('booking_id' => booking['booking_id'], 'status' => 'cancelled', 'reason' => 'property_declined')
  end
end

RSpec.describe 'A hotel that declines a booking', 'twice at once', type: :story do
  include_context 'a hotel that answers on demand'

  it 'a hotel whose answer runs twice at once refunds the guest once' do
    guest = a_guest
    booking = guest.reserves
    expect(guest.pays_for(booking)).to be_ok
    Rails.configuration.x.hoteling.decline_rate = 1

    refunds = Concurrent::AtomicFixnum.new
    allow(Kiosk.configuration.payment_provider).to receive(:refund).and_wrap_original do |refund, **args|
      refunds.increment
      sleep 0.2
      refund.call(**args)
    end
    answers = Array.new(2) do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { PropertyDecisionJob.perform_now(booking['booking_id']) } }
    end
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { answers.each(&:join) }

    expect(refunds.value).to eq(1)
    expect(Booking.find(booking['booking_id'])).to have_attributes(status: 'cancelled', payment_status: 'refunded')
  end
end
