# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

# A standalone assistant is claimed onto a human's account and pays with her saved card.
class ClaimTest < WireTest
  HANA = "00000000-0000-0000-0000-000000000042"
  CARD = "cus_getgrocery_saved_card"

  setup do
    @provider = Kiosk.configuration.payment_provider
    without_test_card = Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch("STRIPE_SECRET_KEY"))
    Kiosk.configuration.payment_provider = @provider.over(without_test_card)
    Kiosk::PaymentProviders::Stripe::CustomerRecord.create!(user_id: HANA, customer_id: CARD)
  end

  teardown { Kiosk.configuration.payment_provider = @provider }

  def approve_as_hana(user_code)
    hana = Kiosk::UserIdentityProviders::DeviseSession.new(live_url)
                                                     .sign_in!(email: "hana@example.com", password: "getgrocery-demo-password")
    page = hana.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
    assert_equal "200", page.code
    assert_equal "200", hana.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve").code
  end

  def poll_token(shopper, device_code)
    pem = shopper.rsa_key.public_key.to_pem
    _, challenge = Kiosk::Redteam::Wire.new(base_url: live_url).get_json("/kiosk/auth/challenge", public_key: pem)
    proof = JWT.encode({ aud: live_url, nonce: challenge["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i },
                       shopper.rsa_key, "RS256")
    answer = Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"),
                                 grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code:, signed: proof)
    assert_equal "200", answer.code, answer.body
    JSON.parse(answer.body).fetch("access_token")
  end

  test "the same key, rebound to the human, pays with the human's saved card" do
    standalone = register
    left_behind = order(standalone, "banana")
    setup = client.run(standalone, name: "payment_setup")
    assert_equal [200, "setup_required"], [setup.status, setup.body["status"]]

    grant = client.device_authorization(client_id: "getgrocery-claim", public_key: standalone.rsa_key.public_key.to_pem)
    assert_equal 200, grant.status, grant.body
    assert_empty %w[device_code user_code verification_uri expires_in interval] - grant.body.keys
    approve_as_hana(grant.body["user_code"])

    hana = standalone.with(user_id: HANA, token: poll_token(standalone, grant.body["device_code"]))
    claims = JWT.decode(hana.token, nil, false).first
    assert_equal [standalone.agent_id, HANA], claims.values_at("agent_id", "sub")
    assert_empty my_order_ids(hana)
    assert_equal standalone.user_id, Order.find(left_behind["order_id"]).user_id

    ready = client.run(hana, name: "payment_setup")
    assert_equal [200, "ready"], [ready.status, ready.body["status"]]
    groceries = order(hana, "banana")
    paid = pay(hana, groceries)
    assert_equal 200, paid.status, paid.body
    assert_match(/\Api_/, paid.body["psp_reference"])
    assert_equal [groceries["order_id"]], my_order_ids(hana)
    assert_equal [[HANA, standalone.agent_id]], Kiosk::Settlement.pluck(:user_id, :agent_id)
    assert_equal CARD, Kiosk::PaymentProviders::Stripe::CustomerRecord.find_by!(user_id: HANA).customer_id
  end
end
