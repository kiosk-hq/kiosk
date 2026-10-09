# frozen_string_literal: true

require "test_helper"
require "kiosk/user_identity_providers/devise_session"

class HouseholdStory < StoryTest
  Response = Data.define(:status, :body)

  setup do
    @alice = User.find_by!(email: "alice@example.com")
    @site  = Kiosk::UserIdentityProviders::DeviseSession.new(live_url)
                                                        .sign_in!(email: @alice.email, password: "philslist-demo-password")
  end

  # Alice, signed in on the board's site, links an assistant to her account.
  def alice_links_an_assistant
    key = OpenSSL::PKey::RSA.generate(2048)
    _, link = @site.post_json("/kiosk/auth/link", {}, { session: true })
    status, claimed = @site.post_json("/kiosk/auth/claim", { code: link.fetch("link_code"), public_key: key.public_to_pem, signed: proof(key) })
    assert_equal [201, @alice.id], [status, claimed["user_id"]]
    seller_holding(key, claimed.fetch("access_token"))
  end

  # A new assistant asks to join Alice's account and shows her a code to approve.
  def a_new_assistant_asks_alice(key)
    request = assistant.device_authorization(client_id: "philslist-test", public_key: key.public_to_pem)
    assert_equal 200, request.status
    assert_empty %w[device_code user_code verification_uri expires_in interval] - request.body.keys
    request.body
  end

  def alice_approves(user_code)
    page = @site.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
    approved = @site.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve",
                                                             "authenticity_token" => @site.csrf_token(page.body))
    assert_equal "200", approved.code
  end

  def still_waiting?(request, key)
    answer = collect_credential(request, key)
    answer.code == "400" && JSON.parse(answer.body)["error"] == "authorization_pending"
  end

  def collects_its_credential(request, key)
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
    answer = collect_credential(request, key)
    assert_equal "200", answer.code, answer.body
    seller_holding(key, JSON.parse(answer.body).fetch("access_token"))
  end

  # A fresh credential issued in the same second as Alice's unlink that follows it.
  def signs_in_again(seller)
    proof = proof(seller.principal.rsa_key)
    sleep(1 - (Time.now.to_f % 1) + 0.02)
    Seller.new(assistant, seller.principal.with(token: signs_in(seller, proof:)["access_token"]))
  end

  def signs_in(seller, proof: proof(seller.principal.rsa_key))
    status, body = @site.post_json("/kiosk/auth/login", { public_key: seller.principal.rsa_key.public_to_pem, signed: proof })
    Kiosk::TestHelpers::Answer.new(Response.new(status:, body:))
  end

  def alice_unlinks(seller)
    unlinked, = @site.post_json("/kiosk/auth/unlink", { agent_id: seller.principal.agent_id }, { session: true })
    assert_equal 204, unlinked
  end

  def alices_assistants_page = @site.get_html("/kiosk/auth/assistants").body

  def seller_holding(key, token)
    claims = JWT.decode(token, nil, false).first
    Seller.new(assistant, Kiosk::TestHelpers::Assistant::Principal.new(agent_id: claims["agent_id"], user_id: claims["sub"], token:, rsa_key: key))
  end

  def proof(key)
    _, challenge = @site.get_json("/kiosk/auth/challenge", { public_key: key.public_to_pem })
    JWT.encode({ aud: live_url, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  def collect_credential(request, key)
    Net::HTTP.post_form(URI("#{live_url}/kiosk/oauth/token"), grant_type: "urn:ietf:params:oauth:grant-type:device_code",
                                                              device_code: request.fetch("device_code"), signed: proof(key))
  end

  test "Alice approves a new assistant on the board's site, and it posts as her" do
    key = OpenSSL::PKey::RSA.generate(2048)
    request = a_new_assistant_asks_alice(key)
    assert still_waiting?(request, key)

    alice_approves(request["user_code"])
    hers = collects_its_credential(request, key)
    assert_equal @alice.id, hers.principal.user_id

    desk = hers.posts
    assert desk.ok?, desk
    assert_equal @alice.id, Listing.find(desk["listing_id"]).owner_id
    assert_includes alices_assistants_page, hers.principal.agent_id
  end

  test "a couple's two assistants share one board presence, and unlinking one shuts out only that one" do
    hers, his = alice_links_an_assistant, alice_links_an_assistant
    bookshelf = hers.posts(price_text: "€150")
    assert_includes ids(his.own_listings), bookshelf["listing_id"]
    assert his.edits(bookshelf, price_text: "€140").ok?

    same_second = signs_in_again(hers)
    alice_unlinks(hers)

    assert hers.asks(:my_listings).refused?(:unauthenticated)
    assert same_second.asks(:my_listings).refused?(:unauthenticated)
    assert same_second.edits(bookshelf, price_text: "€1").refused?(:unauthenticated)
    assert_equal "€140", Listing.find(bookshelf["listing_id"]).price_text

    assert his.asks(:my_listings).ok?
    assert signs_in(hers).refused?(:not_found)
    assert signs_in(his).ok?
  end
end
