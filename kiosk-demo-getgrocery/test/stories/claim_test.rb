# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class ClaimStory < StoryTest
  HANA = "00000000-0000-0000-0000-000000000042"
  HANAS_CARD = "cus_getgrocery_saved_card"

  setup do
    @provider = Kiosk.configuration.payment_provider
    without_test_card = Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch("STRIPE_SECRET_KEY"))
    Kiosk.configuration.payment_provider = @provider.over(without_test_card)
    Kiosk::PaymentProviders::Stripe::CustomerRecord.create!(user_id: HANA, customer_id: HANAS_CARD)
  end

  teardown { Kiosk.configuration.payment_provider = @provider }

  # Hana signs in on the shop's site and approves the code her assistant shows her.
  def hana_approves(user_code)
    hana = Kiosk::UserIdentityProviders::DeviseSession.new(live_url)
                                                     .sign_in!(email: "hana@example.com", password: "getgrocery-demo-password")
    assert_equal "200", hana.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}").code
    assert_equal "200", hana.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve").code
  end

  # The assistant collects its new credential once Hana has approved.
  def collects_hanas_credential(shopper, device_code)
    key = shopper.principal.rsa_key
    _, challenge = Kiosk::TestHelpers::Wire.new(base_url: live_url).get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
    proof = JWT.encode({ aud: live_url, nonce: challenge["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
    answer = Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"),
                                 grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code:, signed: proof)
    assert_equal "200", answer.code, answer.body
    Shopper.new(assistant, shopper.principal.with(user_id: HANA, token: JSON.parse(answer.body).fetch("access_token")))
  end

  test "an assistant that started on its own is linked to Hana and pays with her saved card" do
    standalone = a_shopper
    left_behind = standalone.orders("banana")
    assert_equal "setup_required", standalone.does(:payment_setup)["status"]

    link = assistant.device_authorization(client_id: "getgrocery-claim", public_key: standalone.principal.rsa_key.public_key.to_pem)
    assert_equal 200, link.status, link.body
    hana_approves(link.body["user_code"])
    hanas = collects_hanas_credential(standalone, link.body["device_code"])

    assert_empty hanas.orders_placed
    assert_equal standalone.principal.user_id, Order.find(left_behind["order_id"]).user_id

    assert_equal "ready", hanas.does(:payment_setup)["status"]
    groceries = hanas.orders("banana")
    assert hanas.pays_for(groceries).ok?
    assert_equal [groceries["order_id"]], hanas.orders_placed.pluck("order_id")
    assert_equal [[HANA, standalone.principal.agent_id]], Kiosk::Settlement.pluck(:user_id, :agent_id)
  end
end
