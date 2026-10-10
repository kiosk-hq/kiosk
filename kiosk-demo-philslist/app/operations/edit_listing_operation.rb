# frozen_string_literal: true

# Patches the title, body or price of one of the principal's own listings.
class EditListingOperation
  def self.call(listing_id:, changes:)
    listing = Listing.own.find_by(id: listing_id)
    # One answer for absent and foreign, so ids cannot be probed.
    raise Kiosk::Server::Errors::Forbidden.new("listing not owned by the authenticated principal",
                                               hint: "You may only edit your own listings.") unless listing
    listing.update!(changes)

    { listing_id: listing_id, updated: true }
  end
end
