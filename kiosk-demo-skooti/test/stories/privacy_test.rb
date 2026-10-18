# frozen_string_literal: true

require 'test_helper'

class PrivacyStory < StoryTest
  test "one rider can neither pay for, ride, nor see another's reservation" do
    alice = a_rider
    bob = a_rider
    alices = alice.reserves('SK-001')

    assert bob.pays_for(alices).refused?(:forbidden)
    assert_predicate alice.pays_for(alices), :ok?
    assert bob.rides(alices).refused?(:forbidden)

    bobs = bob.reserves('SK-002')

    assert_equal [bobs['reservation_id']], bob.reservations.pluck('reservation_id')
    assert_equal bob.principal.user_id, Reservation.find(bobs['reservation_id']).user_id
  end

  test 'a reservation belongs to the rider who made it, whoever the arguments name' do
    alice = a_rider
    bob = a_rider

    forged = bob.reserves('SK-001', user_id: alice.principal.user_id)

    assert_refused forged, :bad_request
    assert_includes forged['detail'], 'user_id'
  end
end
