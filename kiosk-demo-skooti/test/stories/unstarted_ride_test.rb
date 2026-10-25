# frozen_string_literal: true

require 'test_helper'

class UnstartedRideStory < StoryTest
  def the_hold_runs_out(scooter)
    reservation = Reservation.find(scooter['reservation_id'])
    reservation.update!(held_until: reservation.created_at)
  end

  def refund_notices
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM kiosk_events WHERE topic = 'payment' AND data->>'payment_state' = 'refunded'"
    )
  end

  test 'a paid hold whose ride never starts frees the vehicle and refunds the rider, once' do
    rider = a_rider
    scooter = rider.reserves('SK-001')

    assert_predicate rider.pays_for(scooter), :ok?
    rider.listens_for(:payment)

    the_hold_runs_out(scooter)
    2.times { RefundUnstartedJob.perform_now }

    news = rider.hears(:payment, about: scooter['reservation_id'], payment_state: 'refunded')

    assert_equal({ 'reservation_id' => scooter['reservation_id'], 'payment_state' => 'refunded' }, news)
    assert_equal 'refunded', rider.reservations.sole['payment_state']
    assert_equal 1, refund_notices
    assert_includes a_rider.vehicles_nearby.pluck('code'), 'SK-001'

    refused = rider.rides(scooter)

    assert_refused refused, :conflict
    assert_includes refused['detail'], 'its payment is refunded to the card'
  end

  test 'a started ride keeps its payment' do
    rider = a_rider
    scooter = rider.reserves('SK-001')

    assert_predicate rider.pays_for(scooter), :ok?
    assert_predicate rider.rides(scooter), :ok?

    RefundUnstartedJob.perform_now

    assert_equal 'paid', rider.reservations.sole['payment_state']
  end

  test 'an unpaid hold holds the vehicle three minutes, and a lapsed one cannot be paid for' do
    rider = a_rider
    scooter = rider.reserves('SK-001')
    held = Reservation.find(scooter['reservation_id'])

    assert_in_delta 3.minutes, held.held_until - held.created_at, 1

    the_hold_runs_out(scooter)
    refused = rider.pays_for(scooter)

    assert_refused refused, :forbidden
    assert_includes refused['detail'], 'hold lapsed'
    assert_empty Kiosk::Settlement.all
  end
end
