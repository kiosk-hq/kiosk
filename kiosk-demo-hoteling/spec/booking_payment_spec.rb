# frozen_string_literal: true

require 'spec_helper'

# A PSP that settles every capture at once.
class InstantPsp
  def capture(checkout, **)
    { psp_reference: 'pi_fixture', settled_amount_cents: checkout.total_amount_cents, settled_at: Time.now.utc }
  end
end

RSpec.shared_context 'with a booking two customers can pay for' do
  let(:ada) { User.create!(email: 'ada-pay@example.test', password: 'payment-fixture') }
  let(:ben) { User.create!(email: 'ben-pay@example.test', password: 'payment-fixture') }

  let(:booking) do
    property  = Property.create!(name: 'Pay Fixture', city: 'Istanbul', stars: 4, amenities: [])
    room_type = RoomType.create!(property: property, name: 'Double', nightly_price_cents: 18_000)
    Booking.create!(user: ada, property: property, room_type: room_type,
                    check_in: Date.current + 30, check_out: Date.current + 31, total_cents: 18_000)
  end

  let(:cashier) { Kiosk.configuration.payment_provider.over(InstantPsp.new) }

  def checkout(payer)
    Kiosk::Mandate::CheckoutMandate.new(
      reference: SecureRandom.uuid, checkout_hash: SecureRandom.uuid, user_id: payer.id,
      agent_id: SecureRandom.uuid, issuer: 'https://hoteling.test',
      line_items: [{ 'booking_id' => booking.id }, { 'qty' => 1, 'price_cents' => 18_000 }],
      total_amount_cents: 18_000, currency: 'eur', expires_at: nil, sd_jwt: 'checkout'
    )
  end
end

RSpec.describe Booking do
  describe 'paying for a booking' do
    include_context 'with a booking two customers can pay for'

    it "refuses a customer paying for somebody else's booking" do
      expect { cashier.capture(checkout(ben)) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, 'booking not found or not yours')
      expect(booking.reload).to be_unpaid
    end

    it "takes the owner's payment, and the property confirms the paid booking" do
      paid = checkout(ada)
      cashier.capture(paid)
      cashier.settled(paid)

      expect(booking.reload).to be_paid.and be_confirmed
      expect(booking.confirmation_code).to be_present
    end

    it "names the booking in the checkout receipt's order_id, the field AP2 gives that id" do
      receipt = Kiosk::Server::Receipts.issue(checkout: checkout(ada), payment: checkout(ada), settlement_id: 'settlement',
                                              psp_reference: 'pi_fixture', network_confirmation_id: nil)

      expect(JWT.decode(receipt[:checkout_receipt], nil, false).first['order_id']).to eq(booking.id)
    end
  end
end
