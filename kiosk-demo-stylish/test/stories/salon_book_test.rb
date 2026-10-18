# frozen_string_literal: true

require 'test_helper'

class SalonBookStory < StoryTest
  test "the owner's assistant sees every booking and what they will bring in" do
    alices = assistant_of(:alice).books('Colour')['appointment_id']
    bobs   = assistant_of(:bob).books('Cut')['appointment_id']
    owner  = assistant_of(:owner)

    assert_equal 'owner', owner.role

    book = owner.the_book.rows

    assert_equal [alices, bobs].sort, book.pluck('id').sort
    assert_equal 12_500, book.pluck('price_cents').sum
    assert_equal ['eur'], book.pluck('currency').uniq
  end

  test "a client's assistant sees only the client's own booking" do
    alice  = assistant_of(:alice)
    alices = alice.books['appointment_id']
    assistant_of(:bob).books

    assert_equal 'customer', alice.role

    assert_equal [alices], alice.the_book.rows.pluck('id')
  end

  test "a client's assistant reads its appointments oldest booking first" do
    alice  = assistant_of(:alice)
    booked = Array.new(3) { alice.books['appointment_id'] }
    booked.sort.reverse.each_with_index { |id, age| Appointment.find(id).update!(created_at: (10 - age).minutes.ago) }

    assert_equal booked.sort.reverse, alice.appointments
  end
end
