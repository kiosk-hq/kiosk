# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/kyc"

class KycTest < WireTest
  include Kiosk::TestHelpers::Kyc

  def rent_motorcycle(rider, reservation) = assistant.run(rider, name: "rent_motorcycle", reservation_id: reservation["reservation_id"])

  def paid_reservation(rider, scooter_code)
    reservation = reserve(rider, scooter_code)
    assert_equal 200, pay(rider, reservation).status
    reservation
  end

  test "a motorcycle opens once the rider's licence check passes" do
    rider = register
    reservation = paid_reservation(rider, "MC-001")

    refused = rent_motorcycle(rider, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
    assert_includes refused.body["hint"], "request_kyc"

    events = assistant.events(rider)
    events.subscribe("kyc_verification")
    check = assistant.run(rider, name: "request_kyc")
    assert_equal 200, check.status
    assert check.body["verification_url"]

    kyc_check_passes(check.body["request_id"], age_over_18: true, licence_a: true)
    event = events.await { _1["topic"] == "kyc_verification" && _1.dig("data", "request_id") == check.body["request_id"] }
    events.close
    assert_equal "approved", event.dig("data", "status")

    rental = rent_motorcycle(rider, reservation)
    assert_equal 200, rental.status, rental.body
    assert lock("MC-001").unlock(token: rental.body["rental_token"], now: Time.now.to_i)
  end

  test "a check that passes without the licence opens no motorcycle" do
    rider = register
    reservation = paid_reservation(rider, "MC-001")

    kyc_check_passes(assistant.run(rider, name: "request_kyc").body["request_id"], age_over_18: true)

    refused = rent_motorcycle(rider, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
  end

  test "an attestation that spells a boolean any other way grants nothing" do
    rider = register
    reservation = paid_reservation(rider, "MC-001")
    assert_equal 200, assistant.kyc(rider, attestation_jws: kyc_attestation(rider, age_over_18: true, licence_a: true)).status
    assert_equal 200, rent_motorcycle(rider, reservation).status

    spelled = assistant.kyc(rider, attestation_jws: kyc_attestation(rider, age_over_18: "true", licence_a: 1))
    assert_equal [200, {}], [spelled.status, spelled.body["attributes"]]
    refused = rent_motorcycle(rider, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
  end

  test "another rider's attestation grants nothing" do
    rider, thief = register, register
    reservation = paid_reservation(thief, "MC-001")

    stolen = assistant.kyc(thief, attestation_jws: kyc_attestation(rider, age_over_18: true, licence_a: true))
    assert_equal 403, stolen.status
    refused = rent_motorcycle(thief, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
  end

  test "a licence-free scooter needs no attestation" do
    rider = register
    reservation = paid_reservation(rider, "SK-001")
    assert_equal 200, assistant.run(rider, name: "start_rental", reservation_id: reservation["reservation_id"]).status
  end
end
