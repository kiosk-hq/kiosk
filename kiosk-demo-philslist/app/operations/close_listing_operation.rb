# frozen_string_literal: true

# close_listing — OWNER-ONLY. Take one of the authenticated principal's own
# listings off the public board.
class CloseListingOperation
  # Same owner-scoped single statement and shape guard as {EditListingOperation}
  # (K-581/K-582): a malformed id answers 400, a well-formed foreign one 403.
  def self.call(listing_id:)
    id, refusal = ListingAccess.listing_id(listing_id)
    return refusal if refusal

    updated = Listing.owned_by_current_principal
                     .where(id: id)
                     .update_all(status: "closed", updated_at: Time.current)

    return ListingAccess.not_owner("close") if updated.zero?

    OperationResult.ok({ listing_id: id, status: "closed" })
  end
end
