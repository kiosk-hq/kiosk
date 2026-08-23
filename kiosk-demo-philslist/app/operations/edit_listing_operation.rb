# frozen_string_literal: true

# edit_listing — OWNER-ONLY. Patch the display attributes of one of the
# authenticated principal's own listings.
class EditListingOperation
  # @param listing_id [Object] the raw wire value — shape is checked by
  #   {ListingAccess.listing_id}
  # @param changes [Hash] the ALREADY-ALLOWLISTED attributes to patch; the
  #   allowlist stays in the controller, where `permit` belongs. What arrives
  #   here is a plain attribute hash.
  def self.call(listing_id:, changes:)
    id, refusal = ListingAccess.listing_id(listing_id)
    return refusal if refusal

    # All three attributes are declared `type: "string"`, so a JSON number or
    # boolean is coerced HERE — the persistence layer's String type would render
    # `true` as Postgres' "t". nil is preserved: it is how a caller clears a value.
    patch = changes.transform_values { |value| value.nil? ? nil : value.to_s }

    # `update_all`, not `update!`: one statement, so the ownership test and the
    # write cannot be separated by another transaction. `updated_at` always
    # bumps, so a patch supplying nothing still proves ownership by row count.
    updated = Listing.owned_by_current_principal
                     .where(id: id)
                     .update_all(patch.merge(updated_at: Time.current))

    return ListingAccess.not_owner("edit") if updated.zero?

    # The id is echoed back VERBATIM; it is never read back out of the database.
    OperationResult.ok({ listing_id: id, updated: true })
  end
end
