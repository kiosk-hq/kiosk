# frozen_string_literal: true

require "test_helper"

# THE REPLACE PATH HAS EXACTLY THE TWO OUTCOMES ITS DESCRIPTOR NAMES (K-1748).
#
# `create_order` publishes two: it creates an order, or it REPLACES an unpaid
# one in place. `order_id` is the caller's statement of which it means, and an
# id that names nothing replaceable used to fall through to the create — a
# SECOND billable order, reported `ok`, with only the returned `order_id`
# differing from the one that was sent. No descriptor tells a caller to compare
# those, so the commonplace cases (a stale id, a mistyped one, an order that
# went `paid` between a `my_orders` read and this call) each ended as a
# duplicate order the human pays for twice.
#
# These examples drive the REGISTERED handler through the same GUC-scoped
# session the wire opens, with the verb's own `input_schema` validated first —
# so a case that could not be sent over the wire cannot pass here either.
class CreateOrderReplaceTest < ActiveSupport::TestCase
  ADDRESS = "42 Camden Street, Dublin 2"

  setup do
    @shopper = User.create!(email: "replace@example.test", password: "conformance-fixture-password")
    @other   = User.create!(email: "other@example.test",   password: "conformance-fixture-password")
    Product.create!(sku: "sourdough-bread", name: "Sourdough Bread", price_cents: 449, stock: 20)
  end

  test "an order that is still replaceable is replaced IN PLACE, keeping its id" do
    first = place
    again = place(order_id: first["order_id"], qty: 3)

    assert_equal first["order_id"], again["order_id"], "the replace must keep the order's identity"
    assert_equal 1347, again["total_cents"]
    assert_equal 1, Order.where(user_id: @shopper.id).count
  end

  test "an order that is already paid is REFUSED, and no second order is created" do
    paid = place
    Order.where(id: paid["order_id"]).update_all(status: Order::PAID)

    refusal = assert_refused { place(order_id: paid["order_id"]) }
    assert_equal "forbidden", refusal.code
    assert_equal 403, refusal.http_status
    assert_equal 1, Order.where(user_id: @shopper.id).count, "nothing may be created by a refused replace"
    assert_equal Order::PAID, Order.find(paid["order_id"]).status
  end

  test "an order whose payment is in flight is REFUSED, and no second order is created" do
    paying = place
    Order.where(id: paying["order_id"]).update_all(status: Order::PAYING)

    refusal = assert_refused { place(order_id: paying["order_id"]) }
    assert_equal "forbidden", refusal.code
    assert_equal 1, Order.where(user_id: @shopper.id).count
  end

  test "a well-formed order_id that exists nowhere is REFUSED, not turned into a new order" do
    refusal = assert_refused { place(order_id: "99999999-9999-4999-8999-999999999999") }
    assert_equal "forbidden", refusal.code
    assert_equal 0, Order.where(user_id: @shopper.id).count
  end

  test "another principal's order is refused in the SAME words as an unknown one" do
    theirs = place(as: @other)
    mine   = assert_refused { place(order_id: theirs["order_id"]) }
    absent = assert_refused { place(order_id: "99999999-9999-4999-8999-999999999999") }

    assert_equal absent.message, mine.message,
                 "distinguishing the two would let a caller enumerate other principals' order ids"
    assert_equal 0, Order.where(user_id: @shopper.id).count
  end

  private

  def origin = Kiosk::TestHelpers::Conformance.require_origin!

  def place(order_id: nil, qty: 1, as: nil)
    params = { items: [{ sku: "sourdough-bread", qty: qty }],
               delivery_slot_id: 3,
               delivery_date:    DeliverySlots.example_date.iso8601,
               delivery_address: ADDRESS }
    params[:order_id] = order_id if order_id
    origin.call("create_order", kind: :action, params: params, as: as || @shopper)
  end

  # A refusal reaches a caller as the wire's typed error, not as a return value.
  def assert_refused
    error = assert_raises(StandardError) { yield }
    assert_respond_to error, :code, "a refusal must carry the wire's own code (got #{error.class})"
    error
  end
end
