# frozen_string_literal: true

# Patches the title, body or price of one of the seller's own listings.
class EditListingOperation
  def self.call(listing_id:, changes:)
    Listing.own!(listing_id).update!(changes)
    { listing_id: listing_id, updated: true }
  end
end
