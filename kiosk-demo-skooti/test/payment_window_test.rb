# frozen_string_literal: true

require "test_helper"

# A reservation reads `paid` from the moment the PSP captures, not from the
# moment the settlement row lands; and racing pays charge it at most once.
class PaymentWindowTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::SeededDatabase

  class BlockingPsp
    def initialize = @gate = Queue.new
    def release! = @gate << :go
    def setup_required?(*) = false

    def capture(cart_mandate, payment_method: nil)
      @gate.pop
      { psp_reference: "pi_blocking", settled_amount_cents: cart_mandate.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  class CountingPsp
    attr_reader :captures

    def initialize = @captures = Concurrent::AtomicFixnum.new
    def setup_required?(*) = false

    def capture(cart_mandate, payment_method: nil)
      @captures.increment
      sleep 0.05
      { psp_reference: "pi_counting", settled_amount_cents: cart_mandate.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  setup do
    @rider    = User.create!
    @scooter  = Scooter.scooter.first
    @identity = Kiosk::Identity.new(user_id: @rider.id, role: "customer", actor: "agent", agent_id: SecureRandom.uuid)
  end

  def as_rider(&)
    Kiosk::Server::CurrentRequest.with(identity: @identity) do
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: @identity, &)
    end
  end

  def reserve = as_rider { Kiosk::Server::Actions.fetch("reserve").call(scooter_code: @scooter.code) }["reservation_id"]
  def start_rental(id) = as_rider { Kiosk::Server::Actions.fetch("start_rental").call(reservation_id: id) }
  def payment_state(id) = as_rider { Kiosk::Server::Queries.fetch("my_reservations").call({}) }.find { _1["reservation_id"] == id }["payment_state"]
  def payment_status(id) = Reservation.uncached { Reservation.find(id).payment_status }

  def capture(psp, reservation_id)
    cart = Kiosk::Mandate::CartMandate.new(
      id: SecureRandom.uuid, intent_mandate_id: SecureRandom.uuid, user_id: @rider.id, agent_id: @identity.agent_id,
      issuer: Kiosk.configuration.issuer, line_items: [{ "qty" => 1, "price_cents" => @scooter.price_per_min_cents, "reservation_id" => reservation_id }],
      total_amount_cents: @scooter.price_per_min_cents, currency: "eur", expires_at: nil, created_at: nil, raw_jws: "cart",
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

  test "an untouched reservation reads unpaid and does not start" do
    id = reserve
    assert_equal "unpaid", payment_state(id)
    error = assert_raises(Kiosk::Server::Errors::Forbidden) { start_rental(id) }
    assert_includes error.message, "this reservation is not paid"
  end

  test "a capture in flight reads pending, and a returned capture reads paid before its settlement row" do
    id  = reserve
    psp = BlockingPsp.new
    paying = Thread.new { capture(psp, id) }

    assert wait_until { payment_status(id) == "paying" }
    assert_equal "pending", payment_state(id)
    error = assert_raises(Kiosk::Server::Errors::Forbidden) { start_rental(id) }
    assert_includes error.message, "in progress"

    psp.release!
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { paying.join }
    assert_equal "paid", payment_state(id)
    assert_predicate start_rental(id)["rental_token"], :present?

    events = Kiosk.configuration.event_store.since(@rider.id, 0).select { _1["topic"] == "booking_payment" }
    assert_equal [id], events.map { _1["subject"] }
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)
  end

  test "racing pays charge a reservation once" do
    id  = reserve
    psp = CountingPsp.new
    racers = Array.new(4) do
      Thread.new do
        capture(psp, id)
        :captured
      rescue Kiosk::Server::Errors::Base
        :refused
      end
    end
    outcomes = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { racers.map(&:value) }

    assert_equal 1, psp.captures.value
    assert_equal 1, outcomes.count(:captured)
    assert_equal "paid", payment_state(id)
  end
end
