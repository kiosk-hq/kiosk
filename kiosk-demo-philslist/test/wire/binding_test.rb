# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

# A human links assistants to their own account, and unlinks them.
class BindingTest < WireTest
  Assistant = Data.define(:key, :token) do
    def principal = Kiosk::TestHelpers::Assistant::Principal.new(agent_id: claims["agent_id"], user_id: claims["sub"], token:, rsa_key: key)
    def claims = JWT.decode(token, nil, false).first
  end

  setup do
    @alice   = User.find_by!(email: "alice@example.com")
    @session = Kiosk::UserIdentityProviders::DeviseSession.new(live_url).sign_in!(email: @alice.email, password: PASSWORD)
  end

  def proof(key)
    pem = key.public_to_pem
    _, challenge = @session.get_json("/kiosk/auth/challenge", { public_key: pem })
    JWT.encode({ aud: live_url, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  def poll(device_code, key)
    Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"), grant_type: "urn:ietf:params:oauth:grant-type:device_code",
                                                              device_code:, signed: proof(key))
  end

  def link_assistant
    key = OpenSSL::PKey::RSA.generate(2048)
    _, link = @session.post_json("/kiosk/auth/link", {}, { session: true })
    status, claimed = @session.post_json("/kiosk/auth/claim", { code: link.fetch("link_code"), public_key: key.public_to_pem, signed: proof(key) })
    assert_equal [201, @alice.id], [status, claimed["user_id"]]
    Assistant.new(key:, token: claimed.fetch("access_token"))
  end

  def login(assistant) = @session.post_json("/kiosk/auth/login", { public_key: assistant.key.public_to_pem, signed: proof(assistant.key) })

  def my_listings(token) = @session.get_json("/kiosk/my_listings", {}, { "Authorization" => "Bearer #{token}" })

  test "the device grant binds a new assistant to the human who approves it" do
    key = OpenSSL::PKey::RSA.generate(2048)
    opened = client.device_authorization(client_id: "philslist-test", public_key: key.public_to_pem)
    assert_equal 200, opened.status
    assert_empty %w[device_code user_code verification_uri expires_in interval] - opened.body.keys
    device_code, user_code = opened.body.values_at("device_code", "user_code")

    pending = poll(device_code, key)
    assert_equal ["400", "authorization_pending"], [pending.code, JSON.parse(pending.body)["error"]]

    verify = @session.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
    approved = @session.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve",
                                                                "authenticity_token" => @session.csrf_token(verify.body))
    assert_equal "200", approved.code

    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
    granted = poll(device_code, key)
    assert_equal "200", granted.code, granted.body
    assistant = Assistant.new(key:, token: JSON.parse(granted.body).fetch("access_token"))
    assert_equal @alice.id, assistant.claims["sub"]

    listing = post_listing(assistant.principal)
    assert_equal @alice.id, Listing.find(listing).owner_id
    assert_includes @session.get_html("/kiosk/auth/assistants").body, assistant.claims["agent_id"]
  end

  test "a household's assistants share one account, and unlinking one revokes only its tokens" do
    first  = link_assistant
    second = link_assistant
    listing = post_listing(first.principal, price_text: "€150")
    assert_includes my_listings(second.token).last.map { _1["listing_id"] }, listing
    assert_equal 200, client.run(second.principal, name: "edit_listing", listing_id: listing, price_text: "€140").status

    proof = proof(first.key)
    sleep(1 - (Time.now.to_f % 1) + 0.02)
    _, relogged = @session.post_json("/kiosk/auth/login", { public_key: first.key.public_to_pem, signed: proof })
    unlinked, = @session.post_json("/kiosk/auth/unlink", { agent_id: first.claims["agent_id"] }, { session: true })
    assert_equal 204, unlinked
    same_second = relogged.fetch("access_token")

    assert_equal 401, my_listings(first.token).first
    assert_equal 401, my_listings(same_second).first
    write = client.run(first.principal.with(token: same_second), name: "edit_listing", listing_id: listing, price_text: "€1")
    assert_equal 401, write.status
    assert_equal "€140", Listing.find(listing).price_text

    assert_equal 200, my_listings(second.token).first
    assert_equal 404, login(first).first
    assert_equal 200, login(second).first
  end
end
