# frozen_string_literal: true

require 'test_helper'

class ShelfStory < StoryTest
  test 'a price change after ordering does not change what the shopper pays' do
    shopper = a_shopper
    order = shopper.orders('banana')
    Product.find_by!(sku: 'banana').update!(price_cents: 199)

    assert shopper.pays_for(order).ok?
    assert_equal 149, Kiosk::Settlement.sole.settled_amount_cents
  end

  test 'an item that is out of stock cannot be ordered' do
    refused = a_shopper.orders('banana', 'milk-1l')
    assert refused.refused?(:conflict), refused
    assert_includes refused.detail, 'milk-1l'
    assert_equal 0, Order.count
  end

  test 'a paid order takes its items off the shelf' do
    shopper = a_shopper
    assert shopper.pays_for(shopper.orders('banana', 'cheddar')).ok?
    assert_equal({ 'banana' => 79, 'cheddar' => 17 }, Product.where(sku: %w[banana cheddar]).pluck(:sku, :stock).to_h)
  end

  test 'an item that sells out before the shopper pays is not charged for' do
    shopper = a_shopper
    order = shopper.orders('butter-250g')
    Product.find_by!(sku: 'butter-250g').update!(stock: 0)

    refused = shopper.pays_for(order)
    assert refused.refused?(:forbidden), refused
    assert_includes refused.detail, 'butter-250g'
    assert_empty Kiosk::Settlement.all
  end
end
