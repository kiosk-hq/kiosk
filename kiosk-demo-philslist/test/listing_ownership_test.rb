# frozen_string_literal: true

require "test_helper"

class ListingOwnershipTest < ActiveSupport::TestCase
  setup do
    @alice   = User.create!(email: "alice@example.test", password: "test-password")
    @bob     = User.create!(email: "bob@example.test", password: "test-password")
    @listing = Listing.create!(owner: @alice, category: Category.create!(slug: "bikes", name: "Bikes"),
                               title: "Road bike", body: "54cm", price_text: "€300")
  end

  test "the owner edits and closes their listing" do
    as(@alice) do
      assert_equal({ listing_id: @listing.id, updated: true },
                   EditListingOperation.call(listing_id: @listing.id, changes: { "price_text" => nil }))
      assert_equal({ listing_id: @listing.id, status: "closed" }, CloseListingOperation.call(listing_id: @listing.id))
    end
    assert_nil @listing.reload.price_text
    assert @listing.closed?
  end

  test "a foreign listing and an absent one are refused alike" do
    as(@bob) do
      [@listing.id, SecureRandom.uuid].each do |id|
        edit = assert_raises(Kiosk::Server::Errors::Forbidden) { EditListingOperation.call(listing_id: id, changes: { "title" => "x" }) }
        close = assert_raises(Kiosk::Server::Errors::Forbidden) { CloseListingOperation.call(listing_id: id) }
        assert_equal "listing not owned by the authenticated principal", edit.message
        assert_equal edit.message, close.message
        assert_equal "You may only edit your own listings.", edit.hint
        assert_equal "You may only close your own listings.", close.hint
      end
    end
    assert @listing.reload.open?
    assert_equal "Road bike", @listing.title
  end

  test "an edit cannot blank the title" do
    as(@alice) do
      assert_raises(ActiveRecord::RecordInvalid) do
        EditListingOperation.call(listing_id: @listing.id, changes: { "title" => "" })
      end
    end
    assert_equal "Road bike", @listing.reload.title
  end
end
