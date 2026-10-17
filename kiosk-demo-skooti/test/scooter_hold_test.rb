# frozen_string_literal: true

require 'test_helper'

# The database lets one live reservation hold a vehicle at a time.
class ScooterHoldTest < ActiveSupport::TestCase
  setup do
    @scooter = Scooter.create!(code: 'SK-100', name: 'Hold Test', dock: 'Test Dock', lat: 52.37, lng: 4.88,
                               price_per_min_cents: 15)
  end

  def hold(scooter = @scooter) = Reservation.create!(user: User.create!, scooter:)

  test 'a second live reservation of one vehicle is refused by the database' do
    hold
    assert_raises(ActiveRecord::ExclusionViolation) { hold }
  end

  test 'a lapsed hold frees the vehicle' do
    lapsed = hold
    lapsed.update!(held_until: lapsed.created_at)
    assert hold
  end
end
