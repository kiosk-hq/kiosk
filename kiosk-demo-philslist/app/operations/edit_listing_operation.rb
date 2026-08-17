# frozen_string_literal: true

# edit_listing — OWNER-ONLY. Patch the display attributes of one of the
# authenticated principal's own listings.
class EditListingOperation
  # @param listing_id [Object] the raw wire value — shape is checked by
  #   {ListingAccess.listing_id}
  # @param changes [Hash] the ALREADY-ALLOWLISTED attributes to patch. The
  #   allowlist itself (`params.permit(:title, :body, :price_text)`) stays in the
  #   controller because `permit` is an ActionController::Parameters method and
  #   nothing else on this path knows that type — it is what keeps `status`,
  #   `owner_id` and `created_by_agent_id` unwritable from the wire, and it
  #   belongs where the wrapper it strips comes from. What arrives here is a plain
  #   attribute hash, which is the only shape an Operation should have to know.
  def self.call(listing_id:, changes:)
    id, refusal = ListingAccess.listing_id(listing_id)
    return refusal if refusal

    # All three attributes are declared `type: "string"`, so a scalar that
    # arrives as a JSON number or boolean is coerced HERE rather than wherever
    # the persistence layer would do it: ActiveModel's String type renders `true`
    # as Postgres' "t", which is not what a free-form display price should say.
    # nil is preserved as nil — supplying an explicit null is how a caller clears
    # price_text, and that is why the allowlist hands over absent keys as absent
    # rather than as nils.
    patch = changes.transform_values { |value| value.nil? ? nil : value.to_s }

    # `update_all` (not `update!`) is deliberate — it is one statement, so the
    # ownership test and the write cannot be separated by another transaction,
    # and it skips validations exactly as the previous UPDATE did. `updated_at`
    # always bumps, so a patch that supplies nothing still proves ownership
    # through the row count.
    updated = Listing.owned_by_current_principal
                     .where(id: id)
                     .update_all(patch.merge(updated_at: Time.current))

    return ListingAccess.not_owner("edit") if updated.zero?

    # The id is echoed back VERBATIM as the caller sent it, which is what the
    # handler did — it never read the id back out of the database.
    OperationResult.ok({ listing_id: id, updated: true })
  end
end
