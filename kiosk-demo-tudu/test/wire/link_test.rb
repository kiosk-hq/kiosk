# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class LinkTest < WireTest
  setup do
    @assistant = register
    @list_id   = create_list(@assistant)
  end

  def alice = @alice ||= Kiosk::UserIdentityProviders::DeviseSession.new(live_url).sign_in!(email: "alice@example.com", password: "tudu-demo-password")

  def link_code
    status, link = alice.post_json("/kiosk/auth/link", {}, { session: true })
    assert_equal 201, status
    link.fetch("link_code")
  end

  def proof(key)
    _, challenge = wire.get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
    JWT.encode({ aud: live_url, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  def claim(key, code = link_code)
    claimed = wire.post("/kiosk/auth/claim", { code:, public_key: key.public_key.to_pem, signed: proof(key) })
    assert_equal 201, claimed.status, claimed.body
    claimed.body
  end

  def login(key)
    logged_in = wire.post("/kiosk/auth/login", { public_key: key.public_key.to_pem, signed: proof(key) })
    assert_equal 200, logged_in.status, logged_in.body
    @assistant.with(token: logged_in.body.fetch("access_token"))
  end

  def owns_hike?(assistant) = client.query(assistant, name: "my_lists").body.include?({ "list_id" => @list_id, "title" => "Hike", "role" => "owner" })

  test "linking a headless assistant moves its list to the human and ends every pre-link token" do
    code = link_code
    sleep(1.0 - (Time.now.to_f % 1.0))
    same_second = login(@assistant.rsa_key)
    claimed = claim(@assistant.rsa_key, code)
    assert_equal [ALICE_ID, @assistant.agent_id], claimed.values_at("user_id", "agent_id")

    assert_equal 401, client.query(@assistant, name: "my_lists").status
    assert_equal 401, client.query(same_second, name: "my_lists").status

    relogged = login(@assistant.rsa_key)
    assert_equal ALICE_ID, JWT.decode(relogged.token, nil, false).first["sub"]
    assert owns_hike?(relogged)
    assert_equal ALICE_ID, List.find(@list_id).account_id
    assert_includes alice.get_html("/lists").body, "Hike"

    assert_equal ALICE_ID, claim(OpenSSL::PKey::RSA.generate(2048))["user_id"]
    assert owns_hike?(relogged), "a second assistant leaves the first one bound"
  end

  test "re-linking an assistant already bound to the human moves nothing and destroys nothing" do
    claim(@assistant.rsa_key)
    relinked = claim(@assistant.rsa_key)
    assert_equal [ALICE_ID, @assistant.agent_id], relinked.values_at("user_id", "agent_id")

    assert owns_hike?(@assistant.with(token: relinked.fetch("access_token")))
    assert_equal ["Flat 3B", "Hike"], List.joins(:memberships).where(memberships: { account_id: ALICE_ID }).pluck(:title).sort
  end

  test "the list page shows a member the roster and turns away a human who is not on the list" do
    claim(@assistant.rsa_key)
    page = alice.get_html("/lists/#{@list_id}")
    assert_equal "200", page.code
    assert_includes page.body, "Alice <span class=\"role\">(owner)</span>"

    foreign = alice.get_html("/lists/#{SecureRandom.uuid}")
    assert_includes %w[302 303], foreign.code
    assert_not_includes foreign.body, "Members"
  end
end
