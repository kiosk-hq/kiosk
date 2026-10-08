# frozen_string_literal: true

# Takes one of the principal's own listings off the board.
class CloseListingOperation
  def self.call(listing_id:)
    listing = Listing.own.find_by(id: listing_id)
    # One answer for absent and foreign, so ids cannot be probed.
    raise Kiosk::Server::Errors::Forbidden.new("listing not owned by the authenticated principal",
                                               hint: "You may only close your own listings.") unless listing

    listing.closed!
    { listing_id: listing_id, status: listing.status }
  end
end
