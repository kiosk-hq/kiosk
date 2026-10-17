# frozen_string_literal: true

# Takes one of the seller's own listings off the board.
class CloseListingOperation
  def self.call(listing_id:)
    listing = Listing.own!(listing_id)
    listing.closed!
    { listing_id: listing_id, status: listing.status }
  end
end
