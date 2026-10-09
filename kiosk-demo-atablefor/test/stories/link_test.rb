# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class LinkStory < StoryTest
  def diego = User.find_by!(email: "diego@example.com")

  # Diego signs in on the restaurant site and asks for a code to give his assistant.
  def diego_hands_over_a_link_code
    session = Kiosk::UserIdentityProviders::DeviseSession.new(live_url)
    session.sign_in!(email: diego.email, password: "atablefor-demo-password")
    status, link = session.post_json("/kiosk/auth/link", {}, session: true)
    assert_equal 201, status, link
    link["link_code"]
  end

  # The assistant proves it holds its key and redeems the code for Diego's account.
  def an_assistant_claims(link_code)
    key = OpenSSL::PKey::RSA.generate(2048)
    wire = Kiosk::TestHelpers::Wire.new(base_url: live_url)
    _, challenge = wire.get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
    proof = JWT.encode({ aud: live_url, nonce: challenge["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
    status, claimed = wire.post_json("/kiosk/auth/claim", { code: link_code, public_key: key.public_key.to_pem, signed: proof })
    assert_equal 201, status, claimed
    Diner.new(assistant, Kiosk::TestHelpers::Assistant::Principal.new(
      agent_id: claimed["agent_id"], user_id: claimed["user_id"], token: claimed["access_token"], rsa_key: key,
    ))
  end

  test "Diego links his assistant from the restaurant site, and the table it books is his" do
    diner = an_assistant_claims(diego_hands_over_a_link_code)
    assert_equal diego.id, diner.principal.user_id

    booking = diner.books
    assert booking.ok?, booking
    assert_equal [booking["booking_id"]], diner.bookings
    assert_equal diego.id, Booking.find(booking["booking_id"]).user_id
  end
end
