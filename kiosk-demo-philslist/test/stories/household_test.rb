# frozen_string_literal: true

require "test_helper"

class HouseholdStory < StoryTest
  setup { @alice = a_person(email: "alice@example.com", password: "philslist-demo-password") }

  def alices_account = User.find_by!(email: "alice@example.com").id

  test "Alice approves a new assistant on the board's site, and it posts as her" do
    newcomer = a_newcomer(as: Seller)
    request  = newcomer.asks_to_be_linked(client_id: "philslist-test")
    assert_empty %w[device_code user_code verification_uri expires_in interval] - request.rows.keys
    assert newcomer.polls(request).refused?(:authorization_pending)

    @alice.approves(request["user_code"])
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
    hers = newcomer.collects(request)
    assert_equal alices_account, hers.account

    desk = hers.posts
    assert desk.ok?, desk
    assert_equal alices_account, Listing.find(desk["listing_id"]).owner_id
    assert_includes @alice.visits("/kiosk/auth/assistants").body, hers.principal.agent_id
  end

  test "a couple's two assistants share one board presence, and unlinking one shuts out only that one" do
    hers, his = @alice.links(a_newcomer(as: Seller)), @alice.links(a_newcomer(as: Seller))
    bookshelf = hers.posts(price_text: "€150")
    assert_includes ids(his.own_listings), bookshelf["listing_id"]
    assert his.edits(bookshelf, price_text: "€140").ok?

    sleep(1 - (Time.now.to_f % 1))
    same_second = hers.with_a_fresh_credential
    @alice.unlinks(hers)

    assert hers.asks(:my_listings).refused?(:unauthenticated)
    assert same_second.asks(:my_listings).refused?(:unauthenticated)
    assert same_second.edits(bookshelf, price_text: "€1").refused?(:unauthenticated)
    assert_equal "€140", Listing.find(bookshelf["listing_id"]).price_text

    assert his.asks(:my_listings).ok?
    assert hers.signs_back_in.refused?(:not_found)
    assert his.signs_back_in.ok?
  end
end
