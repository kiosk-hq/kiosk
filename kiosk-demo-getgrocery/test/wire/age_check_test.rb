# frozen_string_literal: true

require "test_helper"
require_relative "../prove_broker"

# Wine is sold only to a shopper whose age the KYC broker has attested.
class AgeCheckTest < WireTest
  BROKER_KEY = File.expand_path("../../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__)

  setup { ProveBroker.start }

  def attest(shopper, signing_key: OpenSSL::PKey.read(File.read(BROKER_KEY)), **attributes)
    now = Time.now.to_i
    JWT.encode({ sub: shopper.user_id, level: "verified", iss: ENV.fetch("KIOSK_PROVE_ISSUER"), aud: "getgrocery",
                 attributes:, iat: now, exp: now + 3600 }, signing_key, "RS256")
  end

  def buy_wine(shopper) = create_order(shopper, ["table-red-wine"])

  test "wine is sold once the shopper's age is attested through the broker" do
    shopper = register
    refused = buy_wine(shopper)
    assert_equal [403, "kyc_required"], [refused.status, refused.body["code"]]
    assert_includes refused.body["hint"], "request_kyc"

    stream = Kiosk::TestHelpers::Assistant::Events.new(base_url: live_url, token: shopper.token)
    stream.subscribe("kyc_verification")
    request = client.run(shopper, name: "request_kyc")
    assert_equal 200, request.status
    assert_includes request.body["verification_url"], "/verify?request="
    2.times { assert_equal 200, client.run(shopper, name: "request_kyc").status }
    capped = client.run(shopper, name: "request_kyc")
    assert_equal [429, "quota_exceeded"], [capped.status, capped.body["code"]]

    approval = Net::HTTP.post_form(URI.join(request.body["verification_url"], "/verify"),
                                   request: request.body["request_id"], decision: "approve")
    assert_equal "200", approval.code
    event = stream.await { _1["topic"] == "kyc_verification" && _1.dig("data", "request_id") == request.body["request_id"] }
    stream.close
    assert_equal "approved", event.dig("data", "status")

    attested = client.kyc(shopper, attestation_jws: event.dig("data", "kyc_jws"))
    assert_equal 200, attested.status
    assert_equal true, attested.body.dig("attributes", "age_over_18")

    sold = buy_wine(shopper)
    assert_equal 200, sold.status, sold.body
    paid = pay(shopper, sold.body.merge("skus" => ["table-red-wine"]))
    assert_equal 200, paid.status, paid.body

    events = Kiosk.configuration.event_store.since(shopper.user_id, 0).select { _1["topic"] == "kyc_verification" }
    assert_empty Kiosk::TestHelpers::Assistant::Events.payload_errors(JSON.parse(Kiosk::Server::SchemaDocument.json), events)
    reachable = Kiosk::Server::Events.fetch("kyc_verification")[:subject_reachable]
    owner    = Kiosk::Identity.new(user_id: shopper.user_id, role: "customer", actor: "agent", agent_id: shopper.agent_id)
    stranger = Kiosk::Identity.new(user_id: SecureRandom.uuid, role: "customer", actor: "agent", agent_id: SecureRandom.uuid)
    assert events.all? { reachable.call(_1["subject"], owner) }
    assert events.none? { reachable.call(_1["subject"], stranger) }
  end

  test "groceries with no age restriction need no attestation" do
    assert_equal 200, create_order(register, ["banana"]).status
  end

  test "an attestation the broker did not sign grants nothing" do
    shopper = register
    forged = client.kyc(shopper, attestation_jws: attest(shopper, signing_key: OpenSSL::PKey::RSA.generate(2048), age_over_18: true))
    assert_equal 403, forged.status
    assert_equal [403, "kyc_required"], buy_wine(shopper).then { [_1.status, _1.body["code"]] }

    assert_equal 200, client.kyc(shopper, attestation_jws: attest(shopper, age_over_18: true)).status
    assert_equal 200, buy_wine(shopper).status
  end

  test "an attestation that spells the boolean any other way grants nothing" do
    shopper = register
    assert_equal 200, client.kyc(shopper, attestation_jws: attest(shopper, age_over_18: true)).status
    assert_equal 200, buy_wine(shopper).status

    spelled = client.kyc(shopper, attestation_jws: attest(shopper, age_over_18: "true"))
    assert_equal [200, {}], [spelled.status, spelled.body["attributes"]]
    assert_equal [403, "kyc_required"], buy_wine(shopper).then { [_1.status, _1.body["code"]] }
  end
end
