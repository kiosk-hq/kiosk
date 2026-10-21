# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/in_process_wire'

# A reservation reads `paid` from the moment the PSP captures, not from the
# moment the settlement row lands; and racing pays charge it at most once.
class PaymentWindowTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::SeededDatabase

  class BlockingPsp
    def initialize = @gate = Queue.new
    def release! = @gate << :go
    def setup_required?(*) = false

    def capture(checkout_mandate, **)
      @gate.pop
      { psp_reference: 'pi_blocking', settled_amount_cents: checkout_mandate.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  class CountingPsp
    attr_reader :captures

    def initialize = @captures = Concurrent::AtomicFixnum.new
    def setup_required?(*) = false

    def capture(checkout_mandate, **)
      @captures.increment
      sleep 0.05
      { psp_reference: 'pi_counting', settled_amount_cents: checkout_mandate.total_amount_cents, settled_at: Time.now.utc }
    end
  end

  setup do
    @rider    = User.create!
    @scooter  = Scooter.scooter.first
    @identity = Kiosk::Identity.new(user_id: @rider.id, role: 'customer', actor: 'agent', agent_id: SecureRandom.uuid)
  end

  # The verb through its route, as the rider's assistant.
  def as_rider(name, kind, **params) = Kiosk::TestHelpers::InProcessWire.new.call(name, kind:, params:, identity: @identity)

  def reserve = as_rider('reserve', :action, scooter_code: @scooter.code)['reservation_id']
  def start_rental(id) = as_rider('start_rental', :action, reservation_id: id)
  def payment_state(id) = as_rider('my_reservations', :query).find { it['reservation_id'] == id }['payment_state']
  def payment_status(id) = Reservation.uncached { Reservation.find(id).payment_status }

  def capture(psp, reservation_id)
    checkout = Kiosk::Mandate::CheckoutMandate.new(
      reference: SecureRandom.uuid, checkout_hash: SecureRandom.uuid, user_id: @rider.id, agent_id: @identity.agent_id,
      issuer: Kiosk.configuration.issuer, line_items: [{ 'qty' => 1, 'price_cents' => @scooter.price_per_min_cents, 'reservation_id' => reservation_id }],
      total_amount_cents: @scooter.price_per_min_cents, currency: 'eur', expires_at: nil, sd_jwt: 'checkout'
    )
    ActiveRecord::Base.connection_pool.with_connection { Kiosk.configuration.payment_provider.over(psp).capture(checkout) }
  end

  def eventually?
    50.times do
      return true if yield

      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { sleep 0.05 }
    end
    false
  end

  # Runs the block while the PSP holds the capture, then lets the capture return.
  def pay_through_a_held_capture(id)
    psp = BlockingPsp.new
    paying = Thread.new { capture(psp, id) }

    assert(eventually? { payment_status(id) == 'paying' })
    yield if block_given?
    psp.release!
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { paying.join }
  end

  test 'an untouched reservation reads unpaid and does not start' do
    id = reserve

    assert_equal 'unpaid', payment_state(id)
    error = assert_raises(Kiosk::Server::Errors::WireError) { start_rental(id) }
    assert_includes error.message, 'this reservation is not paid'
  end

  test 'a capture in flight reads pending and does not start' do
    id = reserve

    pay_through_a_held_capture(id) do
      assert_equal 'pending', payment_state(id)
      error = assert_raises(Kiosk::Server::Errors::WireError) { start_rental(id) }
      assert_includes error.message, 'in progress'
    end
  end

  test 'a returned capture reads paid before its settlement row, and starts' do
    id = reserve
    pay_through_a_held_capture(id)

    assert_equal 'paid', payment_state(id)
    assert_predicate start_rental(id)['rental_token'], :present?
  end

  test 'a returned capture publishes one payment event the schema describes' do
    id = reserve
    pay_through_a_held_capture(id)
    events = Kiosk.configuration.event_store.since(@rider.id, 0).select { it['topic'] == 'payment' }

    assert_equal([id], events.pluck('subject'))
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)
  end

  test 'racing pays charge a reservation once' do
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
    assert_equal 'paid', payment_state(id)
  end
end
