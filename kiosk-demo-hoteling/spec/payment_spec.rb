# frozen_string_literal: true

require "spec_helper"

RSpec.describe "paying for a booking" do
  let(:ada) { User.create!(email: "ada-pay@example.test", password: "payment-fixture") }
  let(:ben) { User.create!(email: "ben-pay@example.test", password: "payment-fixture") }

  let(:property)  { Property.create!(name: "Pay Fixture", city: "Istanbul", stars: 4, amenities: []) }
  let(:room_type) { RoomType.create!(property: property, name: "Double", nightly_price_cents: 18_000) }
  let(:booking) do
    Booking.create!(user: ada, property: property, room_type: room_type,
                    check_in: Date.current + 30, check_out: Date.current + 31, total_cents: 18_000)
  end

  let(:psp) do
    Class.new do
      def capture(cart, payment_method: nil)
        { psp_reference: "pi_fixture", settled_amount_cents: cart.total_amount_cents, settled_at: Time.now.utc }
      end
    end.new
  end
  let(:cashier) { Kiosk.configuration.payment_provider.over(psp) }

  def cart(payer)
    Kiosk::Mandate::CartMandate.new(
      id: SecureRandom.uuid, intent_mandate_id: SecureRandom.uuid, user_id: payer.id,
      agent_id: SecureRandom.uuid, issuer: "https://hoteling.test",
      line_items: [{ "booking_id" => booking.id }, { "qty" => 1, "price_cents" => 18_000 }],
      total_amount_cents: 18_000, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart",
    )
  end

  def confirm(as:)
    identity = Kiosk::Identity.new(user_id: as.id, role: "customer", actor: "agent", agent_id: SecureRandom.uuid)
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.lease_connection, identity: identity) do
      ConfirmBookingOperation.call(booking_id: booking.id)
    end
  end

  before do
    Rails.configuration.x.hoteling.decision_delay_seconds = 0
    Rails.configuration.x.hoteling.decline_rate           = 0
  end

  it "refuses a principal paying for somebody else's booking" do
    expect { cashier.capture(cart(ben)) }
      .to raise_error(Kiosk::Server::Errors::Forbidden, "booking not found or not yours")
    expect(booking.reload).to be_unpaid
  end

  it "takes the owner's payment, and the property's answer is what confirm_booking hands back" do
    cashier.capture(cart(ada))

    expect(booking.reload).to be_paid.and be_confirmed
    expect(confirm(as: ada)).to eq(booking_id: booking.id, status: "confirmed",
                                   confirmation_code: booking.confirmation_code)
    expect { confirm(as: ben) }.to raise_error(Kiosk::Server::Errors::Forbidden, "booking not found or not yours")
  end

  it "refuses to confirm an unpaid booking" do
    expect { confirm(as: ada) }.to raise_error(Kiosk::Server::Errors::Forbidden, "no settlement for this booking")
  end
end
