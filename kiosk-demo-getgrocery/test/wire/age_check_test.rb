# frozen_string_literal: true

require "test_helper"
require "kiosk/test_helpers/kyc"

# Wine is sold only to a shopper whose age check has passed.
class AgeCheckTest < WireTest
  include Kiosk::TestHelpers::Kyc

  def buy_wine(shopper) = create_order(shopper, ["table-red-wine"])

  def refused?(answer) = [answer.status, answer.body["code"]] == [403, "kyc_required"]

  test "wine is sold once the shopper's age check passes" do
    shopper = register
    refused = buy_wine(shopper)
    assert refused?(refused), refused.body
    assert_includes refused.body["hint"], "request_kyc"

    events = assistant.events(shopper)
    events.subscribe("kyc_verification")
    check = assistant.run(shopper, name: "request_kyc")
    assert_equal 200, check.status
    assert check.body["verification_url"]

    kyc_check_passes(check.body["request_id"], age_over_18: true)
    event = events.await { _1["topic"] == "kyc_verification" && _1.dig("data", "request_id") == check.body["request_id"] }
    events.close
    assert_equal "approved", event.dig("data", "status")

    sold = buy_wine(shopper)
    assert_equal 200, sold.status, sold.body
    paid = pay(shopper, sold.body.merge("skus" => ["table-red-wine"]))
    assert_equal 200, paid.status, paid.body
  end

  test "groceries with no age restriction need no age check" do
    assert_equal 200, create_order(register, ["banana"]).status
  end

  test "an attestation someone else signed grants nothing" do
    shopper = register
    claims, = JWT.decode(kyc_attestation(shopper, age_over_18: true), nil, false)
    forged = assistant.kyc(shopper, attestation_jws: JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), "RS256"))
    assert_equal 403, forged.status
    assert refused?(buy_wine(shopper))

    assert_equal 200, assistant.kyc(shopper, attestation_jws: kyc_attestation(shopper, age_over_18: true)).status
    assert_equal 200, buy_wine(shopper).status
  end

  test "an attestation that spells the boolean any other way grants nothing" do
    shopper = register
    assert_equal 200, assistant.kyc(shopper, attestation_jws: kyc_attestation(shopper, age_over_18: true)).status
    assert_equal 200, buy_wine(shopper).status

    spelled = assistant.kyc(shopper, attestation_jws: kyc_attestation(shopper, age_over_18: "true"))
    assert_equal [200, {}], [spelled.status, spelled.body["attributes"]]
    assert refused?(buy_wine(shopper))
  end
end
