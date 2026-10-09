# frozen_string_literal: true

require "test_helper"

class SellingStory < StoryTest
  test "Alice's assistant posts an oak desk, lowers its price and closes it (bin/demo)" do
    assert system({ "SERVER_URL" => live_url }, "bin/demo", chdir: Rails.root, out: File::NULL), "bin/demo failed"

    desk = Listing.find_by!(title: "Oak desk")
    assert_equal ["alice@example.com", "€120", "closed"], [desk.owner.email, desk.price_text, desk.status]
  end

  test "a seller who retitles a listing keeps its price, and clears the price only by saying so" do
    seller  = a_seller
    listing = seller.posts(price_text: "€80")

    assert seller.edits(listing, title: "Pine bookshelf").ok?
    assert_equal "€80", seller.price_of(listing)

    assert seller.edits(listing, price_text: nil).ok?
    assert_nil seller.price_of(listing)
  end
end
