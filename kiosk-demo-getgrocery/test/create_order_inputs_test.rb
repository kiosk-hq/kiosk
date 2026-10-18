# frozen_string_literal: true

require 'test_helper'

# `create_order` PLACES AN ORDER. IT TAKES NO EXISTING ORDER TO AMEND.
#
# The only way to change what an unpaid order says is to place another one,
# with every parameter fresh. That is safe because an order nobody pays for is
# never delivered and never charged — this shop acts on paid orders — so the
# row left behind costs its owner nothing.
#
# The published `input_schema` is a CLOSED object (`additionalProperties:
# false`) that declares no `order_id`, which is what makes "there is nothing to
# amend" a fact a caller can read rather than a sentence it has to believe. An
# assistant that sends one is refused, by name, before the handler runs — and
# that refusal is the property worth pinning: silently ignoring the argument
# would mean a SECOND billable order answered `ok`, with only the returned
# `order_id` differing from the one that was sent, and nothing telling a caller
# to compare them.
#
# These examples drive the REGISTERED handler through the same GUC-scoped
# session the wire opens, with the verb's own `input_schema` validated first —
# so a case that could not be sent over the wire cannot pass here either.
class CreateOrderInputsTest < ActiveSupport::TestCase
  ADDRESS = '42 Camden Street, Dublin 2'

  setup do
    @shopper = User.create!(email: 'inputs@example.test', password: 'conformance-fixture-password')
    Product.create!(sku: 'sourdough-bread', name: 'Sourdough Bread', price_cents: 449, stock: 20)
  end

  test 'an order_id argument is REFUSED by the published contract, by name' do
    placed = place
    refusal = assert_kiosk_refused { place(order_id: placed['order_id']) }

    assert_equal [400, 'bad_request'], [refusal.http_status, refusal.code]
    assert_includes refusal.message, 'order_id',
                    'the refusal must name the argument, so an assistant can correct itself'
  end

  test 'a call refused for its order_id argument writes nothing' do
    placed = place

    assert_kiosk_refused { place(order_id: placed['order_id']) }
    assert_equal 1, Order.where(user_id: @shopper.id).count
  end

  test 'a well-formed uuid naming nothing is refused in the same words' do
    refusal = assert_kiosk_refused { place(order_id: '99999999-9999-4999-8999-999999999999') }
    assert_equal 'bad_request', refusal.code
    assert_equal 0, Order.where(user_id: @shopper.id).count
  end

  test 'changing your mind is a NEW order — two calls, two ids, neither amended' do
    first  = place
    second = place(qty: 3)

    assert_not_equal first['order_id'], second['order_id'], 'nothing is replaced in place'
    assert_equal 2, Order.where(user_id: @shopper.id).count
    assert_equal [449, 1347], [first['total_cents'], second['total_cents']]
  end

  test 'slot_at must be the start of a delivery window' do
    refusal = assert_kiosk_refused { place(slot_at: off_grid_slot) }

    assert_equal 'bad_request', refusal.code
    assert_includes refusal.message, 'slot_at of a delivery_slots row'
  end

  test 'a call refused for its slot_at writes nothing' do
    assert_kiosk_refused { place(slot_at: off_grid_slot) }
    assert_equal 0, Order.where(user_id: @shopper.id).count
  end

  test "an abandoned order stays unpaid on the customer's own reconciliation surface" do
    place
    rows = kiosk_origin.call('my_orders', kind: :query, params: {}, as: @shopper)

    assert_equal 1, rows.length
    assert_equal 'unpaid', rows.first['payment_state'],
                 'nothing is charged for an order nobody paid for'
  end

  private

  def off_grid_slot = (DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2] + 30.minutes).iso8601

  def place(order_id: nil, qty: 1, slot_at: DeliverySlots.starts(DeliverySlots.default_zone.tomorrow)[2].iso8601)
    params = { items: [{ sku: 'sourdough-bread', qty: qty }],
               slot_at: slot_at,
               delivery_address: ADDRESS }
    params[:order_id] = order_id if order_id
    kiosk_origin.call('create_order', kind: :action, params: params, as: @shopper)
  end
end
