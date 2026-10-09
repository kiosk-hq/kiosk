# frozen_string_literal: true

require "wire_helper"

RSpec.describe "the property's answer to a paid booking", :wire do
  before { Rails.configuration.x.hoteling.decision_delay_seconds = 1.hour }

  def decide(booking, decline_rate:)
    Rails.configuration.x.hoteling.decline_rate = decline_rate
    PropertyDecisionJob.perform_now(booking.id)
    booking.reload
  end

  def confirmations(user_id)
    events = Kiosk.configuration.event_store.since(user_id, 0).select { _1["topic"] == "booking_confirmation" }
    expect(Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)).to be_empty
    events.map { _1["data"] }
  end

  it "is awaited, then accepting mints the code the guest is handed, once" do
    guest   = register
    booking = reserve(guest)
    expect(pay(guest, booking).status).to eq(200)
    row = Booking.find(booking["booking_id"])

    silent = confirm(guest, booking)
    expect([silent.status, silent.body["detail"]]).to eq([403, "the property has not answered this booking yet"])
    expect(row.reload).to have_attributes(status: "reserved", confirmation_code: nil)

    code = decide(row, decline_rate: 0).confirmation_code
    expect(row).to be_confirmed
    expect(code).to be_present
    expect(confirmations(guest.user_id)).to eq([{ "booking_id" => row.id, "status" => "confirmed", "confirmation_code" => code }])
    expect(confirm(guest, booking).body).to include("status" => "confirmed", "confirmation_code" => code)

    expect(decide(row, decline_rate: 1)).to have_attributes(status: "confirmed", confirmation_code: code)
  end

  it "declining cancels the booking, frees its nights and refunds the charge" do
    guest   = register
    booking = reserve(guest)
    expect(pay(guest, booking).status).to eq(200)
    charge = Kiosk::Settlement.find_by!(user_id: guest.user_id).psp_reference

    row = decide(Booking.find(booking["booking_id"]), decline_rate: 1)
    expect(row).to have_attributes(status: "cancelled", payment_status: "refunded", payment_state: "refunded")
    expect(row.refund_psp_reference).to start_with("re_")
    expect(Booking.live.where(id: row.id)).to be_empty
    expect(confirmations(guest.user_id)).to eq([{ "booking_id" => row.id, "status" => "cancelled", "reason" => "property_declined",
                                                  "refund" => { "amount_cents" => row.total_cents, "currency" => "eur",
                                                                "psp_reference" => row.refund_psp_reference, "reverses" => charge } }])
  end

  it "declining a booking that was never charged refunds nothing" do
    room = RoomType.first
    row  = Booking.create!(user: User.first, property: room.property, room_type: room, total_cents: room.nightly_price_cents,
                           check_in: Date.current + 30, check_out: Date.current + 31, payment_status: :paid)

    expect(decide(row, decline_rate: 1)).to have_attributes(status: "cancelled", refund_psp_reference: nil)
    expect(confirmations(row.user_id)).to eq([{ "booking_id" => row.id, "status" => "cancelled", "reason" => "property_declined" }])
  end
end
