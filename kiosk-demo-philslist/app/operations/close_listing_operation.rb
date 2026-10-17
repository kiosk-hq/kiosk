# frozen_string_literal: true

# Takes one of the seller's own listings off the board.
class CloseListingOperation
  def self.call(listing_id:)
    Listing.own!(listing_id).tap(&:closed!)
  end
end
