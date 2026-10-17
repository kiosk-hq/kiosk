# frozen_string_literal: true

require 'test_helper'

class UnstartedRideStory < StoryTest
  def the_hold_runs_out(scooter) = Reservation.where(id: scooter['reservation_id']).update_all('held_until = created_at')

  def refund_notices
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM kiosk.events WHERE topic = 'booking_payment' AND data->>'payment_state' = 'refunded'"
    )
  end

  test 'a paid hold whose ride never starts frees the vehicle and refunds the rider, once' do
    rider = a_rider
    scooter = rider.reserves('SK-001')
    assert rider.pays_for(scooter).ok?
    rider.listens_for(:booking_payment)

    the_hold_runs_out(scooter)
    2.times { RefundUnstartedJob.perform_now }

    news = rider.hears(:booking_payment, about: scooter['reservation_id'], payment_state: 'refunded')
    assert_equal({ 'reservation_id' => scooter['reservation_id'], 'payment_state' => 'refunded' }, news)
    assert_equal 'refunded', rider.reservations.sole['payment_state']
    assert_equal 1, refund_notices
    assert_includes a_rider.vehicles_nearby.pluck('code'), 'SK-001'

    refused = rider.rides(scooter)
    assert refused.refused?(:conflict), refused
    assert_includes refused['detail'], 'its payment is refunded to the card'
  end

  test 'a started ride keeps its payment' do
    rider = a_rider
    scooter = rider.reserves('SK-001')
    assert rider.pays_for(scooter).ok?
    assert rider.rides(scooter).ok?

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
    assert refused.refused?(:forbidden), refused
    assert_includes refused['detail'], 'hold lapsed'
    assert_empty Kiosk::Settlement.all
  end
end
