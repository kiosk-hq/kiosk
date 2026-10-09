# frozen_string_literal: true

require "spec_helper"
require "kiosk/test_helpers/live_server"
require "kiosk/redteam"

# A booking reads `paid` from the moment the PSP captures, not from the moment
# the settlement row lands; and racing pays charge it at most once.
RSpec.describe "the window between a capture and its settlement" do
  include Kiosk::TestHelpers::SeededDatabase

  let(:blocking_psp) do
    Class.new do
      def initialize = @gate = Queue.new
      def release! = @gate << :go
      def setup_required?(*) = false

      def capture(cart_mandate, payment_method: nil)
        @gate.pop
        { psp_reference: "pi_blocking", settled_amount_cents: cart_mandate.total_amount_cents, settled_at: Time.now.utc }
      end
    end.new
  end

  let(:counting_psp) do
    Class.new do
      attr_reader :captures

      def initialize = @captures = Concurrent::AtomicFixnum.new
      def setup_required?(*) = false

      def capture(cart_mandate, payment_method: nil)
        @captures.increment
        sleep 0.05
        { psp_reference: "pi_counting", settled_amount_cents: cart_mandate.total_amount_cents, settled_at: Time.now.utc }
      end
    end.new
  end

  let(:guest)    { User.create! }
  let(:room)     { RoomType.first }
  let(:identity) { Kiosk::Identity.new(user_id: guest.id, role: "customer", actor: "agent", agent_id: SecureRandom.uuid) }

  def as_guest(&)
    Kiosk::Server::CurrentRequest.with(identity:) do
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity:, &)
    end
  end

  def reserve
    check_in = Date.current + 30
    as_guest do
      Kiosk::Server::Actions.fetch("reserve_room").call(property_id: room.property_id, room_type_id: room.id,
                                                        check_in: check_in.iso8601, check_out: (check_in + 1).iso8601)
    end["booking_id"]
  end

  def confirm(id) = as_guest { Kiosk::Server::Actions.fetch("confirm_booking").call(booking_id: id) }
  def payment_state(id) = as_guest { Kiosk::Server::Queries.fetch("my_bookings").call({}) }.find { _1["booking_id"] == id }["payment_state"]
  def payment_status(id) = Booking.uncached { Booking.find(id).payment_status }
  def settled?(id) = Kiosk::Settlement.uncached { Kiosk::Settlement.joins(:cart_mandate).merge(Kiosk::CartMandate.referencing(booking_id: id)).exists? }

  def capture(psp, booking_id)
    cart = Kiosk::Mandate::CartMandate.new(
      id: SecureRandom.uuid, intent_mandate_id: SecureRandom.uuid, user_id: guest.id, agent_id: identity.agent_id,
      issuer: Kiosk.configuration.issuer, line_items: [{ "qty" => 1, "price_cents" => room.nightly_price_cents, "booking_id" => booking_id }],
      total_amount_cents: room.nightly_price_cents, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart",
    )
    ActiveRecord::Base.connection_pool.with_connection { Kiosk.configuration.payment_provider.over(psp).capture(cart) }
  end

  def wait_until
    50.times do
      return true if yield
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { sleep 0.05 }
    end
    false
  end

  it "reads an untouched booking unpaid, and does not confirm it" do
    id = reserve
    expect(payment_state(id)).to eq("unpaid")
    expect { confirm(id) }.to raise_error(Kiosk::Server::Errors::Forbidden, "no settlement for this booking")
  end

  it "reads a capture in flight pending, and a returned capture paid before its settlement row" do
    id = reserve
    paying = Thread.new { capture(blocking_psp, id) }

    expect(wait_until { payment_status(id) == "paying" }).to be(true)
    expect(payment_state(id)).to eq("pending")
    expect { confirm(id) }.to raise_error(Kiosk::Server::Errors::Forbidden, /in progress/)

    blocking_psp.release!
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { paying.join }
    expect(settled?(id)).to be(false)
    expect(payment_state(id)).to eq("paid")
    expect(confirm(id)).to include("status" => "confirmed")

    events = Kiosk.configuration.event_store.since(guest.id, 0).select { _1["topic"] == "booking_payment" }
    expect(events.map { _1["subject"] }).to eq([id])
    expect(Kiosk::Redteam::EventStream.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)).to be_empty
  end

  it "charges a booking once however many pays race for it" do
    id = reserve
    racers = Array.new(4) do
      Thread.new do
        capture(counting_psp, id)
        :captured
      rescue Kiosk::Server::Errors::Base
        :refused
      end
    end
    outcomes = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { racers.map(&:value) }

    expect(counting_psp.captures.value).to eq(1)
    expect(outcomes.count(:captured)).to eq(1)
    expect(payment_state(id)).to eq("paid")
  end
end
