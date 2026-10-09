# frozen_string_literal: true

require "test_helper"

class PrivacyStory < StoryTest
  setup do
    @alice, @bob = a_seller, a_seller
    @alices = @alice.posts(price_text: "€80")
    @bobs   = @bob.posts
  end

  test "a buyer browsing the board sees every seller's listings, and among their own only theirs" do
    assert_empty ids([@alices, @bobs]) - ids(@bob.browses)
    assert_equal ids([@bobs]), ids(@bob.own_listings)
  end

  test "one seller can neither edit nor close another's listing" do
    assert @bob.edits(@alices, price_text: "€1").refused?(:forbidden)
    assert @bob.closes(@alices).refused?(:forbidden)
    assert_equal %w[open €80], Listing.find(@alices["listing_id"]).values_at(:status, :price_text)

    assert @alice.edits(@alices, price_text: "€1").ok?
    assert @alice.closes(@alices).ok?
  end

  test "a listing belongs to the seller whose assistant posted it, whoever the arguments name" do
    forged = @bob.posts(title: "Desk", body: "Oak", owner_id: @alice.principal.user_id)
    assert forged.refused?(:bad_request), forged
    assert_includes forged["detail"], "owner_id"

    desk = Listing.find(@bob.posts(title: "Desk")["listing_id"])
    assert_equal [@bob.principal.user_id, @bob.principal.agent_id], [desk.owner_id, desk.created_by_agent_id]
  end

  test "only the board is public; every question about the seller's own listings shows nothing of anyone else's" do
    queries = published("/kiosk/schema")["queries"]
    assert_equal({ "browse_listings" => "published", "my_listings" => "principal" },
                 queries.to_h { [_1["name"], _1["reach"]] })

    own = queries.select { _1["reach"] == "principal" && _1.dig("input_schema", "required").blank? }
    assert_not_empty own
    own.each do |query|
      answer = @bob.asks(query["name"])
      assert answer.ok?, answer
      assert_not_includes ids(answer.rows), @alices["listing_id"], query["name"]
    end
  end
end
