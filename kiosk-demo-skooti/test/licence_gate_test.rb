# frozen_string_literal: true

require 'test_helper'

# Each rental verb activates only the vehicles it is for.
class LicenceGateTest < ActiveSupport::TestCase
  def reservation_of(needs_licence)
    Reservation.new(scooter: Scooter.new(code: 'X-1', needs_licence:))
  end

  test 'start_rental refuses a vehicle that needs a licence' do
    reservation = reservation_of(true)

    assert_not reservation.valid?(:start_rental)
    assert_equal ['X-1 needs a licence — rent it with rent_motorcycle'], reservation.errors[:base]
  end

  test 'rent_motorcycle refuses a vehicle that needs no licence' do
    reservation = reservation_of(false)

    assert_not reservation.valid?(:rent_motorcycle)
    assert_equal ['X-1 needs no licence — rent it with start_rental'], reservation.errors[:base]
  end

  test 'each verb accepts the vehicle it is for' do
    assert_empty reservation_of(false).tap { it.valid?(:start_rental) }.errors[:base]
    assert_empty reservation_of(true).tap { it.valid?(:rent_motorcycle) }.errors[:base]
  end
end
