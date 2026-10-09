# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class LinkStory < StoryTest
  ALICE = "00000000-0000-0000-0000-000000000001"

  setup do
    @on_its_own = a_member
    @hike = @on_its_own.starts_a_list("Hike")
  end

  # Alice, signed in on the site in her browser.
  def alice = @alice ||= Kiosk::UserIdentityProviders::DeviseSession.new(live_url).sign_in!(email: "alice@example.com", password: "tudu-demo-password")

  def alice_shows_a_link_code
    status, link = alice.post_json("/kiosk/auth/link", {}, { session: true })
    assert_equal 201, status
    link.fetch("link_code")
  end

  # The assistant holding `key` redeems the code Alice showed it.
  def alice_links(key, code = alice_shows_a_link_code)
    linked = wire.post("/kiosk/auth/claim", { code:, public_key: key.public_key.to_pem, signed: proof_of(key) })
    assert_equal 201, linked.status, linked.body
    linked.body
  end

  def signs_in_again(member)
    key = member.principal.rsa_key
    signed_in = wire.post("/kiosk/auth/login", { public_key: key.public_key.to_pem, signed: proof_of(key) })
    assert_equal 200, signed_in.status, signed_in.body
    token = signed_in.body.fetch("access_token")
    Member.new(assistant, member.principal.with(token:, user_id: JWT.decode(token, nil, false).first["sub"]))
  end

  def proof_of(key)
    _, challenge = wire.get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
    JWT.encode({ aud: live_url, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  def wire = Kiosk::TestHelpers::Wire.new(base_url: live_url)
  def at_the_start_of_a_second = sleep(1.0 - (Time.now.to_f % 1.0))
  def owns_the_hike?(member) = member.lists.include?({ "list_id" => @hike, "title" => "Hike", "role" => "owner" })

  test "Alice links an assistant that started on its own: its list becomes hers, and every credential it held before stops working" do
    code = alice_shows_a_link_code
    at_the_start_of_a_second
    issued_as_it_links = signs_in_again(@on_its_own)
    linked = alice_links(@on_its_own.principal.rsa_key, code)
    assert_equal [ALICE, @on_its_own.principal.agent_id], linked.values_at("user_id", "agent_id")

    assert @on_its_own.asks(:my_lists).refused?(:unauthenticated)
    assert issued_as_it_links.asks(:my_lists).refused?(:unauthenticated)

    alices = signs_in_again(@on_its_own)
    assert_equal ALICE, alices.account_id
    assert owns_the_hike?(alices)
    assert_equal ALICE, List.find(@hike).account_id
    assert_includes alice.get_html("/lists").body, "Hike"

    assert_equal ALICE, alice_links(OpenSSL::PKey::RSA.generate(2048))["user_id"]
    assert owns_the_hike?(alices), "a second assistant leaves the first one linked"
  end

  test "linking an assistant that is already Alice's again moves nothing and destroys nothing" do
    alice_links(@on_its_own.principal.rsa_key)
    relinked = alice_links(@on_its_own.principal.rsa_key)
    assert_equal [ALICE, @on_its_own.principal.agent_id], relinked.values_at("user_id", "agent_id")

    assert owns_the_hike?(Member.new(assistant, @on_its_own.principal.with(token: relinked.fetch("access_token"))))
    assert_equal ["Flat 3B", "Hike"], List.joins(:memberships).where(memberships: { account_id: ALICE }).pluck(:title).sort
  end

  test "the list page shows Alice who is on her list, and turns her away from a list she is not on" do
    alice_links(@on_its_own.principal.rsa_key)
    page = alice.get_html("/lists/#{@hike}")
    assert_equal "200", page.code
    assert_includes page.body, "Alice <span class=\"role\">(owner)</span>"

    foreign = alice.get_html("/lists/#{SecureRandom.uuid}")
    assert_includes %w[302 303], foreign.code
    assert_not_includes foreign.body, "Members"
  end
end
