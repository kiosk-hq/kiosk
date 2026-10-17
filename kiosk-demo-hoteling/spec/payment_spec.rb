# frozen_string_literal: true

require 'spec_helper'

# A PSP that settles every capture at once.
class InstantPsp
  def capture(cart, **)
    { psp_reference: 'pi_fixture', settled_amount_cents: cart.total_amount_cents, settled_at: Time.now.utc }
  end
end

RSpec.shared_context 'a booking two customers can pay for' do
  let(:ada) { User.create!(email: 'ada-pay@example.test', password: 'payment-fixture') }
  let(:ben) { User.create!(email: 'ben-pay@example.test', password: 'payment-fixture') }

  let(:property)  { Property.create!(name: 'Pay Fixture', city: 'Istanbul', stars: 4, amenities: []) }
  let(:room_type) { RoomType.create!(property: property, name: 'Double', nightly_price_cents: 18_000) }
  let(:booking) do
    Booking.create!(user: ada, property: property, room_type: room_type,
                    check_in: Date.current + 30, check_out: Date.current + 31, total_cents: 18_000)
  end

  let(:cashier) { Kiosk.configuration.payment_provider.over(InstantPsp.new) }

  def cart(payer)
    Kiosk::Mandate::CartMandate.new(
      id: SecureRandom.uuid, intent_mandate_id: SecureRandom.uuid, user_id: payer.id,
      agent_id: SecureRandom.uuid, issuer: 'https://hoteling.test',
      line_items: [{ 'booking_id' => booking.id }, { 'qty' => 1, 'price_cents' => 18_000 }],
      total_amount_cents: 18_000, currency: 'eur', expires_at: nil, created_at: nil, raw_jws: 'cart'
    )
  end
end

RSpec.describe 'paying for a booking' do
  include_context 'a booking two customers can pay for'

  it "refuses a customer paying for somebody else's booking" do
    expect { cashier.capture(cart(ben)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, 'booking not found or not yours')
    expect(booking.reload).to be_unpaid
  end

  it "takes the owner's payment, and the property confirms the paid booking" do
    cashier.capture(cart(ada))

    expect(booking.reload).to be_paid.and be_confirmed
    expect(booking.confirmation_code).to be_present
  end
end
