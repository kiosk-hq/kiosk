# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/in_process_wire'

# The claim an order takes while its capture is in flight, over real row locks.
class PaymentClaimTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::SeededDatabase

  class BlockingPsp
    attr_reader :charged_cents

    def initialize = @gate = Queue.new
    def release! = @gate << :go
    def setup_required?(*) = false

    def capture(checkout_mandate, **)
      @charged_cents = checkout_mandate.total_amount_cents
      @gate.pop
      { psp_reference: 'pi_blocking', settled_amount_cents: @charged_cents, settled_at: Time.now.utc }
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

  setup { @identity = new_shopper }

  def new_shopper = Kiosk::Identity.new(user_id: User.create!.id, role: 'customer', actor: 'agent', agent_id: SecureRandom.uuid)

  # The verb through its route, as the shopper's assistant.
  def as_shopper(name, kind, **params) = Kiosk::TestHelpers::InProcessWire.new.call(name, kind:, params:, identity: @identity)

  def place(sku, qty: 1)
    as_shopper('create_order', :action, items: [{ sku:, qty: }], slot_at: DeliverySlots.starts(Date.current + 1)[2].iso8601,
                                        delivery_address: '42 Camden Street, Dublin 2').merge('sku' => sku)
  end

  def payment_state(order_id) = as_shopper('my_orders', :query).find { it['order_id'] == order_id }['payment_state']
  def status(order_id) = Order.uncached { Order.find(order_id).payment_status }

  def capture(psp, order)
    total = order['total_cents']
    checkout = Kiosk::Mandate::CheckoutMandate.new(
      reference: SecureRandom.uuid, checkout_hash: SecureRandom.uuid, user_id: @identity.user_id, agent_id: @identity.agent_id,
      issuer: Kiosk.configuration.issuer, currency: 'eur', total_amount_cents: total, expires_at: nil,
      line_items: [{ 'order_id' => order['order_id'] }, { 'sku' => order['sku'], 'qty' => 1, 'price_cents' => total }],
      sd_jwt: 'checkout'
    )
    ActiveRecord::Base.connection_pool.with_connection { Kiosk.configuration.payment_provider.over(psp).capture(checkout) }
  end

  def paying?(order_id)
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { sleep 0.05 }
    status(order_id) == 'paying'
  end

  # Holds a capture of `order` open while the block runs, and returns its processor.
  def while_capture_in_flight(order)
    psp = BlockingPsp.new
    paying = Thread.new { capture(psp, order) }
    flunk 'the capture never claimed the order' unless 50.times.any? { paying?(order['order_id']) }
    yield
    psp
  ensure
    psp.release!
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { paying.join }
  end

  test 'an order whose capture is in flight reads pending, then reads paid on the capture alone' do
    order = place('banana')

    while_capture_in_flight(order) { assert_equal 'pending', payment_state(order['order_id']) }

    assert_equal 'paid', payment_state(order['order_id'])
    assert_equal 0, Kiosk::Settlement.count
  end

  test 'an order whose capture is in flight keeps its total when the shopper orders again' do
    order = place('banana')
    psp = while_capture_in_flight(order) do
      assert_not_equal order['order_id'], place('olive-oil', qty: 10)['order_id']
      assert_equal order['total_cents'], Order.find(order['order_id']).total_cents
    end

    assert_equal order['total_cents'], psp.charged_cents
  end

  test 'racing pays charge an order once' do
    order = place('banana')
    psp   = CountingPsp.new
    racers = Array.new(4) do
      Thread.new do
        capture(psp, order)
        :captured
      rescue Kiosk::Server::Errors::Forbidden
        :refused
      end
    end
    outcomes = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { racers.map(&:value) }

    assert_equal 1, psp.captures.value
    assert_equal [:captured] + ([:refused] * 3), outcomes.sort
    assert_equal 'paid', status(order['order_id'])
  end

  test 'a paid order is refused with its status and never reaches the processor again' do
    order = place('banana')
    capture(CountingPsp.new, order)
    psp = CountingPsp.new

    error = assert_raises(Kiosk::Server::Errors::Forbidden) { capture(psp, order) }
    assert_equal "order #{order['order_id']} is already paid (paid) — do not pay it again", error.message
    assert_equal 0, psp.captures.value
  end

  test 'a well-formed order id the caller does not own is a 403, to pay and to move' do
    theirs = place('banana')
    @identity = new_shopper

    assert_raises(Kiosk::Server::Errors::Forbidden) { capture(CountingPsp.new, theirs) }
    error = assert_raises(Kiosk::Server::Errors::WireError) do
      as_shopper('reschedule_delivery', :action, order_id: SecureRandom.uuid, slot_at: DeliverySlots.starts(Date.current + 1)[3].iso8601)
    end
    assert_equal 'forbidden', error.code
  end
end
