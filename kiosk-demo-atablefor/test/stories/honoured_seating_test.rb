# frozen_string_literal: true

require 'test_helper'

class HonouredSeatingStory < StoryTest
  def visits_of(diner) = Kiosk::Visit.where(user_id: diner.principal.user_id).pluck(:value_cents)

  test 'a diner whose seating has passed is recorded as a visit, once, worth the average spend of the party' do
    diner = a_diner
    booking = diner.books(party: 2)
    held = Booking.find(booking['booking_id'])

    SeatingJob.perform_now(held.id)
    assert_empty visits_of(diner)

    travel_to(held.seating_at + 1.minute) { 2.times { SeatingJob.perform_now(held.id) } }
    assert_equal [held.restaurant.average_spend_cents * 2], visits_of(diner)
  end

  test 'a cancelled booking is no visit' do
    diner = a_diner
    booking = diner.books
    assert diner.cancels(booking).ok?

    travel_to(Time.iso8601(booking['seating_at']) + 1.minute) { SeatingJob.perform_now(booking['booking_id']) }
    assert_empty visits_of(diner)
  end
end
