# frozen_string_literal: true

require "test_helper"

# The claim an order takes while its capture is in flight, over real row locks.
class PaymentClaimTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::SeededDatabase

  class BlockingPsp
    attr_reader :charged_cents

    def initialize = @gate = Queue.new
    def release! = @gate << :go
    def setup_required?(*) = false

    def capture(cart_mandate, payment_method: nil)
      @charged_cents = cart_mandate.total_amount_cents
      @gate.pop
      { psp_reference: "pi_blocking", settled_amount_cents: @charged_cents, settled_at: Time.now.utc }
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

  setup { @identity = new_shopper }

  def new_shopper = Kiosk::Identity.new(user_id: User.create!.id, role: "customer", actor: "agent", agent_id: SecureRandom.uuid)

  def as_shopper(&)
    Kiosk::Server::CurrentRequest.with(identity: @identity) do
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: @identity, &)
    end
  end

  def place(sku, qty: 1)
    as_shopper do
      Kiosk::Server::Actions.fetch("create_order").call(
        items: [{ sku:, qty: }], delivery_slot_id: 3, delivery_date: (Date.current + 1).iso8601,
        delivery_address: "42 Camden Street, Dublin 2",
      ).merge("sku" => sku)
    end
  end

  def payment_state(order_id) = as_shopper { Kiosk::Server::Queries.fetch("my_orders").call({}) }.find { _1["order_id"] == order_id }["payment_state"]
  def status(order_id) = Order.uncached { Order.find(order_id).status }

  def capture(psp, order)
    total = order["total_cents"]
    cart = Kiosk::Mandate::CartMandate.new(
      id: SecureRandom.uuid, intent_mandate_id: SecureRandom.uuid, user_id: @identity.user_id, agent_id: @identity.agent_id,
      issuer: Kiosk.configuration.issuer, currency: "eur", total_amount_cents: total, expires_at: nil, created_at: nil,
      line_items: [{ "order_id" => order["order_id"] }, { "sku" => order["sku"], "qty" => 1, "price_cents" => total }],
      raw_jws: "cart",
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

  test "an order whose capture is in flight reads pending and keeps its total, then reads paid on the capture alone" do
    order = place("banana")
    psp   = BlockingPsp.new
    paying = Thread.new { capture(psp, order) }
    assert wait_until { status(order["order_id"]) == "paying" }
    assert_equal "pending", payment_state(order["order_id"])

    dear = place("olive-oil", qty: OrderItem::MAX_QTY)
    assert_not_equal order["order_id"], dear["order_id"]
    assert_equal order["total_cents"], Order.find(order["order_id"]).total_cents

    psp.release!
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { paying.join }
    assert_equal order["total_cents"], psp.charged_cents
    assert_equal "paid", payment_state(order["order_id"])
    assert_equal 0, Kiosk::Settlement.count
  end

  test "racing pays charge an order once" do
    order = place("banana")
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
    assert_equal [:captured] + [:refused] * 3, outcomes.sort
    assert_equal "paid", status(order["order_id"])
  end

  test "an order id that is not a uuid is a 400 that never reaches the processor" do
    psp = CountingPsp.new
    malformed = place("banana").merge("order_id" => "not-a-uuid")
    error = assert_raises(Kiosk::Server::Errors::BadRequest) { capture(psp, malformed) }
    assert_equal [400, "bad_request"], [error.http_status, error.code]
    assert_equal 0, psp.captures.value
  end

  test "a well-formed order id the caller does not own is a 403, to pay and to move" do
    theirs = place("banana")
    @identity = new_shopper

    assert_raises(Kiosk::Server::Errors::Forbidden) { capture(CountingPsp.new, theirs) }
    error = assert_raises(Kiosk::Server::Errors::Forbidden) do
      as_shopper do
        Kiosk::Server::Actions.fetch("reschedule_delivery").call(order_id: SecureRandom.uuid, delivery_slot_id: 4,
                                                                 delivery_date: (Date.current + 1).iso8601)
      end
    end
    assert_equal 403, error.http_status
  end
end
