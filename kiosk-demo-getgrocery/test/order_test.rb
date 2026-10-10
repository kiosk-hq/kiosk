# frozen_string_literal: true

require "test_helper"

class OrderTest < ActiveSupport::TestCase
  SHOP    = DeliverySlots.default_zone
  ADDRESS = "42 Camden Street, Dublin 2"

  setup do
    @bread = Product.create!(sku: "sourdough-bread", name: "Sourdough Bread", price_cents: 449, stock: 20)
  end

  def order(date: Date.new(2026, 9, 8), slot: 3, address: ADDRESS, items: [["sourdough-bread", 1]])
    Order.new(user: User.create!, address:, timezone: SHOP.name, total_cents: 0,
              slot_at: DeliverySlots.slot_at(date, slot, SHOP),
              order_items: items.map { |sku, qty| OrderItem.new(sku:, product: Product.find_by(sku:), qty:) })
  end

  def errors(order, context = :place) = order.tap { _1.validate(context) }.errors.full_messages

  test "an order is delivered to a served district" do
    travel_to SHOP.local(2026, 9, 7, 12) do
      assert_empty errors(order)
      assert_match(/\Adelivery_address is in D24, which getgrocery does not deliver to/, errors(order(address: "Dublin 24")).sole)
      assert_match(/\Adelivery_address is missing/, errors(order(address: "")).sole)
    end
  end

  test "its window has not passed and still reaches the door" do
    travel_to SHOP.local(2026, 9, 7, 11, 30) do
      assert_equal ["delivery window is on 2026-09-06, which is in the past at the delivery address"],
                   errors(order(date: Date.new(2026, 9, 6)))
      assert_match(/\Adelivery window 10:00–12:00 \(Europe\/Dublin\) on 2026-09-07 closes too soon/,
                   errors(order(date: Date.new(2026, 9, 7), slot: 2)).sole)
      assert_empty errors(order(date: Date.new(2026, 9, 7), slot: 3))
    end
  end

  test "a cart names catalogue skus, in bounded quantities" do
    travel_to SHOP.local(2026, 9, 7, 12) do
      assert_equal ['sku "caviar" is not in the catalogue'], errors(order(items: [["caviar", 1]]))
      assert_equal ["qty must be in 1..#{OrderItem::MAX_QTY}"],
                   errors(order(items: [["sourdough-bread", OrderItem::MAX_QTY + 1]]))
      assert_equal ["items are at most #{Order::MAX_ITEMS} lines"],
                   errors(order(items: [["sourdough-bread", 1]] * (Order::MAX_ITEMS + 1)))
    end
  end

  test "a reschedule checks the new window, and a status change checks nothing" do
    placed = travel_to(SHOP.local(2026, 9, 7, 12)) { order.tap { _1.save!(context: :place) } }

    travel_to SHOP.local(2026, 9, 9, 12) do
      assert placed.update!(status: :paid)
      placed.slot_at = DeliverySlots.slot_at(Date.new(2026, 9, 8), 3, SHOP)
      assert_match(/in the past/, errors(placed, :reschedule).sole)
    end
  end
end
