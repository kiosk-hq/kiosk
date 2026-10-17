# frozen_string_literal: true

# Patches the title, body or price of one of the seller's own listings.
class EditListingOperation
  def self.call(listing_id:, changes:)
    Listing.own!(listing_id).tap { it.update!(changes) }
  end
end
