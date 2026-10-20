# frozen_string_literal: true

require 'test_helper'

class OrderTest < ActiveSupport::TestCase
  SHOP    = DeliverySlots.default_zone
  ADDRESS = '42 Camden Street, Dublin 2'

  setup do
    @bread = Product.create!(sku: 'sourdough-bread', name: 'Sourdough Bread', price_cents: 449, stock: 20)
  end

  def order(date: Date.new(2026, 9, 8), slot: 3, address: ADDRESS, items: [['sourdough-bread', 1]])
    Order.new(user: User.create!, address:, timezone: SHOP.name, total_cents: 0,
              slot_at: DeliverySlots.starts(date, SHOP)[slot - 1],
              order_items: items.map { |sku, qty| OrderItem.new(sku:, product: Product.find_by(sku:), qty:, price_cents: 449) })
  end

  def errors(order, context = :place) = order.tap { it.validate(context) }.errors.full_messages

  test 'an order is delivered to a served district' do
    travel_to SHOP.local(2026, 9, 7, 12) do
      assert_empty errors(order)
      assert_match(/\Adelivery_address is in D24, which getgrocery does not deliver to/, errors(order(address: 'Dublin 24')).sole)
      assert_match(/\Adelivery_address is missing/, errors(order(address: '')).sole)
    end
  end

  test 'its window has not passed and still reaches the door' do
    travel_to SHOP.local(2026, 9, 7, 11, 30) do
      assert_match(%r{\Adelivery window 12:00–14:00 \(Europe/Dublin\) on 2026-09-06 is no longer bookable},
                   errors(order(date: Date.new(2026, 9, 6))).sole)
      assert_match(%r{\Adelivery window 10:00–12:00 \(Europe/Dublin\) on 2026-09-07 is no longer bookable},
                   errors(order(date: Date.new(2026, 9, 7), slot: 2)).sole)
      assert_empty errors(order(date: Date.new(2026, 9, 7), slot: 3))
    end
  end

  test 'its window starts on the grid' do
    travel_to SHOP.local(2026, 9, 7, 11, 30) do
      assert_equal ['delivery window must be the slot_at of a delivery_slots row'],
                   errors(order.tap { it.slot_at += 1.hour })
    end
  end

  test 'a cart names catalogue skus, in bounded quantities' do
    travel_to SHOP.local(2026, 9, 7, 12) do
      assert_equal ['sku "caviar" is not in the catalogue'], errors(order(items: [['caviar', 1]]))
      assert_equal ["qty must be in 1..#{OrderItem::MAX_QTY}"],
                   errors(order(items: [['sourdough-bread', OrderItem::MAX_QTY + 1]]))
      assert_equal ["items are at most #{Order::MAX_ITEMS} lines"],
                   errors(order(items: [['sourdough-bread', 1]] * (Order::MAX_ITEMS + 1)))
    end
  end

  test 'a reschedule checks the new window, and a payment checks nothing' do
    placed = travel_to(SHOP.local(2026, 9, 7, 12)) { order.tap { it.save!(context: :place) } }

    travel_to SHOP.local(2026, 9, 9, 12) do
      assert placed.update!(payment_status: :paid)
      placed.slot_at = DeliverySlots.starts(Date.new(2026, 9, 8), SHOP)[2]

      assert_match(/no longer bookable/, errors(placed, :reschedule).sole)
    end
  end

  test 'a payment reported twice takes the basket off the shelf and books the courier once' do
    placed = order(date: Date.tomorrow, items: [['sourdough-bread', 3]])
    placed.update!(payment_status: :paid)

    FulfilOrderOperation.call(placed.id)
    dispatch_at = placed.reload.dispatch_at
    FulfilOrderOperation.call(placed.id)

    assert_equal 17, @bread.reload.stock
    assert_equal dispatch_at, placed.reload.dispatch_at
  end
end
