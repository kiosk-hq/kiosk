# frozen_string_literal: true

require "story_helper"

RSpec.describe "The hotel's answer to a paid booking", type: :story do
  before { Rails.configuration.x.hoteling.decision_delay_seconds = 1.hour }

  def the_hotel_answers(booking, accepts:)
    Rails.configuration.x.hoteling.decline_rate = accepts ? 0 : 1
    PropertyDecisionJob.perform_now(booking["booking_id"])
    Booking.find(booking["booking_id"])
  end

  it "a guest waits for the hotel, and once it accepts is handed the confirmation code, which a later answer does not change" do
    guest = a_guest
    booking = guest.reserves
    expect(guest.pays_for(booking)).to be_ok

    waiting = guest.confirms(booking)
    expect(waiting).to be_refused(:forbidden)
    expect(waiting["detail"]).to eq("the property has not answered this booking yet")
    expect(waiting.hint).to include("booking_confirmation")
    expect(Booking.find(booking["booking_id"])).to have_attributes(status: "reserved", confirmation_code: nil)

    guest.listens_for(:booking_confirmation)
    code = the_hotel_answers(booking, accepts: true).confirmation_code
    expect(code).to be_present
    news = guest.hears(:booking_confirmation, about: booking["booking_id"])
    expect(news).to eq("booking_id" => booking["booking_id"], "status" => "confirmed", "confirmation_code" => code)
    expect(guest.confirms(booking).rows).to include("status" => "confirmed", "confirmation_code" => code)

    expect(the_hotel_answers(booking, accepts: false)).to have_attributes(status: "confirmed", confirmation_code: code)
  end

  it "a hotel that declines cancels the booking, frees its nights and refunds the guest" do
    guest = a_guest
    booking = guest.reserves
    expect(guest.pays_for(booking)).to be_ok
    charge = Kiosk::Settlement.find_by!(user_id: guest.principal.user_id).psp_reference

    guest.listens_for(:booking_confirmation)
    declined = the_hotel_answers(booking, accepts: false)
    expect(declined).to have_attributes(status: "cancelled", payment_status: "refunded", payment_state: "refunded")
    expect(declined.refund_psp_reference).to start_with("re_")
    expect(Booking.live.where(id: declined.id)).to be_empty
    news = guest.hears(:booking_confirmation, about: booking["booking_id"])
    expect(news).to eq("booking_id" => declined.id, "status" => "cancelled", "reason" => "property_declined",
                       "refund" => { "amount_cents" => declined.total_cents, "currency" => "eur",
                                     "psp_reference" => declined.refund_psp_reference, "reverses" => charge })
  end

  it "a hotel that declines a booking with no charge on record refunds nothing" do
    guest = a_guest
    booking = guest.reserves
    Booking.find(booking["booking_id"]).update!(payment_status: :paid)

    guest.listens_for(:booking_confirmation)
    expect(the_hotel_answers(booking, accepts: false)).to have_attributes(status: "cancelled", refund_psp_reference: nil)
    news = guest.hears(:booking_confirmation, about: booking["booking_id"])
    expect(news).to eq("booking_id" => booking["booking_id"], "status" => "cancelled", "reason" => "property_declined")
  end
end
