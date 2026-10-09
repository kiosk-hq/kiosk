# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "kiosk/story_test"

# The categories enum is read from the table, which every story reseeds.
Kiosk::Server::SchemaSlots.refresh_seconds = 0

module ActiveSupport
  class TestCase
    # Runs the block as `user`, the way the wire runs a handler.
    def as(user, &)
      identity = Kiosk::Identity.new(user_id: user.id, role: nil, actor: "human")
      Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity, &)
    end
  end
end

# A seller's AI assistant on the board: browses it, posts a listing, edits and
# closes it, and looks over the seller's own listings.
class Seller < Kiosk::TestHelpers::Customer
  def browses = asks(:browse_listings).rows
  def own_listings = asks(:my_listings).rows

  def posts(category: "furniture", title: "Bookshelf", body: "Pine", **details)
    does(:post_listing, category_slug: category, title:, body:, **details)
  end

  def edits(listing, **changes) = does(:edit_listing, listing_id: listing["listing_id"], **changes)
  def closes(listing) = does(:close_listing, listing_id: listing["listing_id"])

  def price_of(listing) = own_listings.find { _1["listing_id"] == listing["listing_id"] }["price_text"]
end

class StoryTest < Kiosk::StoryTest
  def a_seller = a_customer(as: Seller)

  # What the board publishes to anyone, with no account.
  def published(path)
    status, body = Kiosk::TestHelpers::Wire.new(base_url: live_url).get_json(path)
    assert_equal 200, status, "GET #{path} with no credential"
    body
  end

  def ids(listings) = listings.pluck("listing_id")
end
