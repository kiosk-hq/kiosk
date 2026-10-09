# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class BindingTest < WireTest
  test "a diner links an assistant, and the assistant's bookings are the diner's" do
    diego   = User.find_by!(email: "diego@example.com")
    session = Kiosk::UserIdentityProviders::DeviseSession.new(live_url)
    session.sign_in!(email: diego.email, password: "atablefor-demo-password")
    minted, link = session.post_json("/kiosk/auth/link", {}, session: true)
    assert_equal 201, minted

    key = OpenSSL::PKey::RSA.generate(2048)
    pem = key.public_key.to_pem
    _, challenge = session.get_json("/kiosk/auth/challenge", public_key: pem)
    signed = JWT.encode({ aud: live_url, nonce: challenge["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
    claimed, agent = session.post_json("/kiosk/auth/claim", { code: link["link_code"], public_key: pem, signed: })
    assert_equal [201, diego.id], [claimed, agent["user_id"]]

    assistant = Kiosk::TestHelpers::Assistant::Principal.new(agent_id: agent["agent_id"], user_id: agent["user_id"],
                                              token: agent["access_token"], rsa_key: key)
    booked = book(assistant)
    assert_equal 200, booked.status, booked.body
    assert_equal [booked.body["booking_id"]], my_booking_ids(assistant)
    assert_equal diego.id, Booking.find(booked.body["booking_id"]).user_id
  end
end
