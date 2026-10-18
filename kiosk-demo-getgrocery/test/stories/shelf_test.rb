# frozen_string_literal: true

require 'test_helper'

class ShelfStory < StoryTest
  def sells_out(sku) = Product.find_by!(sku:).update!(stock: 0)
  def shelf(*skus) = Product.where(sku: skus).pluck(:sku, :stock).to_h

  # Runs the block while the shelf of `sku` empties right after the price check passes.
  def another_payment_takes(sku)
    config = Kiosk.configuration
    config.cart_price_checker = ->(*args) { PriceChecker.call(*args).tap { sells_out(sku) } }
    yield
  ensure
    config.cart_price_checker = PriceChecker
  end

  test 'a price change after ordering does not change what the shopper pays' do
    shopper = a_shopper
    order = shopper.orders('banana')
    Product.find_by!(sku: 'banana').update!(price_cents: 199)

    assert_predicate shopper.pays_for(order), :ok?
    assert_equal 149, Kiosk::Settlement.sole.settled_amount_cents
  end

  test 'a sold-out item stays in the catalogue, says when to come back, and cannot be ordered' do
    shopper = a_shopper
    sells_out('milk-1l')

    milk = shopper.browses.rows.find { it['sku'] == 'milk-1l' }

    assert_equal 'Sold out. Check back tomorrow.', milk['sold_out']

    refused = shopper.orders('banana', 'milk-1l')

    assert_refused refused, :conflict
    assert_includes refused.detail, 'milk-1l: Sold out. Check back tomorrow.'
    assert_equal 0, Order.count
  end

  test 'a paid order takes its items off the shelf' do
    shopper = a_shopper

    assert_predicate shopper.pays_for(shopper.orders('banana', 'cheddar')), :ok?
    assert_equal({ 'banana' => Product::DAILY_STOCK - 1, 'cheddar' => Product::DAILY_STOCK - 1 }, shelf('banana', 'cheddar'))
  end

  test 'an item that sells out before the shopper pays is not charged for' do
    shopper = a_shopper
    order = shopper.orders('butter-250g')
    sells_out('butter-250g')

    refused = shopper.pays_for(order)

    assert_refused refused, :forbidden
    assert_includes refused.detail, 'butter-250g: Sold out. Check back tomorrow.'
    assert_empty Kiosk::Settlement.all
  end

  test 'an item another payment takes between the price check and the packing is refunded, the rest delivered' do
    shopper = a_shopper
    order = shopper.orders('butter-250g', 'banana')
    Product.find_by!(sku: 'butter-250g').update!(stock: 1)

    assert_predicate another_payment_takes('butter-250g') { shopper.pays_for(order) }, :ok?
    placed = shopper.orders_placed.sole

    assert_equal 349, placed['refunded_cents']
    assert_equal %w[placed paid], placed.values_at('status', 'payment_state')
    assert_equal({ 'butter-250g' => 0, 'banana' => Product::DAILY_STOCK - 1 }, shelf('butter-250g', 'banana'))
  end

  test 'an order whose every item another payment took is cancelled, refunded in full, and the shopper is told' do
    shopper = a_shopper
    order = shopper.orders('butter-250g')
    shopper.listens_for(:order_delivery)

    assert_predicate another_payment_takes('butter-250g') { shopper.pays_for(order) }, :ok?
    assert_equal({ 'order_id' => order['order_id'], 'status' => 'cancelled' },
                 shopper.hears(:order_delivery, about: order['order_id']))
    assert_equal({ 'status' => 'cancelled', 'payment_state' => 'refunded', 'refunded_cents' => 349 },
                 shopper.orders_placed.sole.slice('status', 'payment_state', 'refunded_cents'))
  end

  test 'every morning the shelves are full again' do
    shopper = a_shopper
    sells_out('milk-1l')

    assert_predicate shopper.pays_for(shopper.orders('banana')), :ok?

    RestockJob.perform_now

    assert_equal({ 'milk-1l' => Product::DAILY_STOCK, 'banana' => Product::DAILY_STOCK }, shelf('milk-1l', 'banana'))
    assert_nil shopper.browses.rows.find { it['sku'] == 'milk-1l' }['sold_out']
  end
end
