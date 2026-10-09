# frozen_string_literal: true

require "test_helper"

class WalkthroughTest < WireTest
  test "bin/demo posts, edits and closes a listing as Alice's assistant" do
    assert system({ "SERVER_URL" => live_url }, "bin/demo", chdir: Rails.root, out: File::NULL), "bin/demo failed"

    desk = Listing.find_by!(title: "Oak desk")
    assert_equal ["alice@example.com", "€120", "closed"], [desk.owner.email, desk.price_text, desk.status]
  end

  test "an omitted price is kept, and an explicit null clears it" do
    seller  = register
    listing = post_listing(seller, price_text: "€80")
    price = -> { client.query(seller, name: "my_listings").body.find { _1["listing_id"] == listing }["price_text"] }

    assert_equal 200, client.run(seller, name: "edit_listing", listing_id: listing, title: "Pine bookshelf").status
    assert_equal "€80", price.call
    assert_equal 200, client.run(seller, name: "edit_listing", listing_id: listing, price_text: nil).status
    assert_nil price.call
  end
end
