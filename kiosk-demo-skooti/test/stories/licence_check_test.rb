# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/kyc"

class LicenceCheckStory < StoryTest
  include Kiosk::TestHelpers::Kyc

  def a_rider_with_a_paid(vehicle)
    rider = a_rider
    reservation = rider.reserves(vehicle)
    assert rider.pays_for(reservation).ok?
    [rider, reservation]
  end

  test "a rider rides a motorcycle once a verification service confirms their motorcycle licence" do
    rider, motorcycle = a_rider_with_a_paid("MC-001")

    refused = rider.rides_motorcycle(motorcycle)
    assert refused.refused?(:kyc_required), refused
    assert_includes refused.hint, "request_kyc"

    assert rider.requests_verification["verification_url"]
    the_verification_service_confirms(rider, age_over_18: true, licence_a: true)
    assert rider.hears_verification_passed

    rental = rider.rides_motorcycle(motorcycle)
    assert rental.ok?, rental
    assert the_lock_on("MC-001").unlock(token: rental["rental_token"], now: Time.now.to_i)
  end

  test "a rider confirmed as an adult but without a motorcycle licence gets no motorcycle" do
    rider, motorcycle = a_rider_with_a_paid("MC-001")

    rider.requests_verification
    the_verification_service_confirms(rider, age_over_18: true)

    assert rider.rides_motorcycle(motorcycle).refused?(:kyc_required)
  end

  test "an attestation that spells the answer any other way than true proves nothing" do
    rider, motorcycle = a_rider_with_a_paid("MC-001")
    assert rider.presents(kyc_attestation(rider.principal, age_over_18: true, licence_a: true)).ok?
    assert rider.rides_motorcycle(motorcycle).ok?

    spelled = rider.presents(kyc_attestation(rider.principal, age_over_18: "true", licence_a: 1))
    assert spelled.ok?, spelled
    assert_equal({}, spelled["attributes"])
    assert rider.rides_motorcycle(motorcycle).refused?(:kyc_required)
  end

  test "another rider's licence opens no motorcycle" do
    licensed = a_rider
    thief, motorcycle = a_rider_with_a_paid("MC-001")

    assert thief.presents(kyc_attestation(licensed.principal, age_over_18: true, licence_a: true)).refused?(:forbidden)
    assert thief.rides_motorcycle(motorcycle).refused?(:kyc_required)
  end

  test "a licence-free scooter needs no licence check" do
    rider, scooter = a_rider_with_a_paid("SK-001")
    assert rider.rides(scooter).ok?
  end
end
