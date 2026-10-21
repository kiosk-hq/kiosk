# frozen_string_literal: true

require 'test_helper'

class ShopStory < StoryTest
  test 'a shopper with no account orders groceries for tomorrow morning and pays' do
    shopper = a_shopper
    groceries = shopper.browses.rows.first(3)
    window = shopper.delivery_windows(date: (Date.current + 1).iso8601).rows.first

    assert_equal '08:00–10:00 (Europe/Dublin)', window['label']

    order = shopper.orders(*groceries.pluck('sku'), slot_at: window['slot_at'])

    assert_predicate order, :ok?, order
    assert_equal groceries.sum { it['price_cents'] }, order['total_cents']

    assert_predicate shopper.pays_for(order), :ok?
    placed = shopper.orders_placed.find { it['order_id'] == order['order_id'] }

    assert_equal ['paid', '08:00–10:00 (Europe/Dublin)'], placed.values_at('payment_state', 'slot_label')
  end

  test 'a paid order is not charged again' do
    shopper = a_shopper
    order = shopper.orders('banana')

    assert_predicate shopper.pays_for(order), :ok?

    # New mandates for a settled checkout: the engine answers 409 before the cashier.
    assert shopper.pays_for(order).refused?(:conflict)
    assert_equal 1, Kiosk::Settlement.where(user_id: shopper.principal.user_id).count
  end

  test 'an address outside the delivery area gets no delivery windows' do
    assert a_shopper.delivery_windows(address: '123 Demo Street, Dublin').refused?(:bad_request)
  end

  test "a shopper's declared zone does not move the day a window is on" do
    day      = DeliverySlots.default_zone.today.iso8601
    declared = a_shopper.delivery_windows(headers: { 'Kiosk-Timezone' => 'Pacific/Niue' }, date: day)

    assert_predicate declared, :ok?, declared
    assert_not_empty declared.rows
    assert_equal a_shopper.delivery_windows(date: day).rows, declared.rows
  end
end
