# frozen_string_literal: true

require "test_helper"
require_relative "../prove_broker"
require_relative "../../script/prove_test_issuer"

class KycTest < WireTest
  setup { ProveBroker.start }

  def rent_motorcycle(rider, reservation) = client.run(rider, name: "rent_motorcycle", reservation_id: reservation["reservation_id"])

  test "a motorcycle opens once the rider's licence is attested through the broker" do
    rider = register
    reservation = reserve(rider, "MC-001")
    assert_equal 200, pay(rider, reservation).status

    refused = rent_motorcycle(rider, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
    assert_includes refused.body["hint"], "request_kyc"

    stream = Kiosk::TestHelpers::Assistant::Events.new(base_url: live_url, token: rider.token)
    stream.subscribe("kyc_verification")
    request = client.run(rider, name: "request_kyc")
    assert_equal 200, request.status
    assert_includes request.body["verification_url"], "/verify?request="
    2.times { assert_equal 200, client.run(rider, name: "request_kyc").status }
    capped = client.run(rider, name: "request_kyc")
    assert_equal [429, "quota_exceeded"], [capped.status, capped.body["code"]]

    approval = Net::HTTP.post_form(URI.join(request.body["verification_url"], "/verify"),
                                   request: request.body["request_id"], decision: "approve")
    assert_equal "200", approval.code
    event = stream.await { _1["topic"] == "kyc_verification" && _1.dig("data", "request_id") == request.body["request_id"] }
    stream.close
    assert_equal "approved", event.dig("data", "status")

    attested = client.kyc(rider, attestation_jws: event.dig("data", "kyc_jws"))
    assert_equal 200, attested.status
    assert_equal({ "age_over_18" => true, "licence_a" => true }, attested.body["attributes"].slice("age_over_18", "licence_a"))

    rental = rent_motorcycle(rider, reservation)
    assert_equal 200, rental.status, rental.body
    assert lock("MC-001").unlock(token: rental.body["rental_token"], now: Time.now.to_i)

    events = Kiosk.configuration.event_store.since(rider.user_id, 0).select { _1["topic"] == "kyc_verification" }
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)
    reachable = Kiosk::Server::Events.fetch("kyc_verification")[:subject_reachable]
    stranger = Kiosk::Identity.new(user_id: SecureRandom.uuid, role: "customer", actor: "agent", agent_id: SecureRandom.uuid)
    owner    = Kiosk::Identity.new(user_id: rider.user_id, role: "customer", actor: "agent", agent_id: rider.agent_id)
    assert events.all? { reachable.call(_1["subject"], owner) }
    assert events.none? { reachable.call(_1["subject"], stranger) }
  end

  test "an attestation that spells a boolean any other way grants nothing" do
    rider = register
    reservation = reserve(rider, "MC-001")
    assert_equal 200, pay(rider, reservation).status
    licensed = ProveTestIssuer.attest(user_id: rider.user_id, attributes: { age_over_18: true, licence_a: true })
    assert_equal 200, client.kyc(rider, attestation_jws: licensed).status
    assert_equal 200, rent_motorcycle(rider, reservation).status

    spelled = client.kyc(rider, attestation_jws: ProveTestIssuer.attest(user_id: rider.user_id,
                                                                       attributes: { age_over_18: "true", licence_a: 1 }))
    assert_equal [200, {}], [spelled.status, spelled.body["attributes"]]
    refused = rent_motorcycle(rider, reservation)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
  end

  test "a licence-free scooter needs no attestation" do
    rider = register
    reservation = reserve(rider, "SK-001")
    assert_equal 200, pay(rider, reservation).status
    assert_equal 200, client.run(rider, name: "start_rental", reservation_id: reservation["reservation_id"]).status
  end
end
