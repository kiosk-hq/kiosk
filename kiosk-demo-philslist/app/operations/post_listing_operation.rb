# frozen_string_literal: true

# post_listing — create a classifieds listing owned by the AUTHENTICATED
# principal, in the section the caller named.
#
# Wire-only today: philslist's public board is read-only and nothing on the human
# surface posts. It is an Operation like its siblings because the seam is about
# where write logic lives, not about how many doors currently reach it.
class PostListingOperation
  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request: `post_listing` deliberately IGNORES a forged
  #   `owner_id` in the body, and it can do that precisely because the value is
  #   passed in from the identity rather than read out of the params.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. The
  #   owner-scoped verbs next door scope with
  #   `Listing.owned_by_current_principal`, which never names the principal
  #   because a WHERE has a predicate to hide it in; an INSERT has no predicate,
  #   so it must supply the value. Both are un-forgeable for the same reason —
  #   the identity is resolved from the Rack env the wire built, which no request
  #   argument can write — but only the first keeps the database as the
  #   authority. Moving the column DEFAULT to `kiosk.current_user_id()` would
  #   close the gap; that is a migration, not part of a handler conversion.
  # @param agent_id [String, nil] the ACTING agent (kiosk.agents.id) —
  #   attribution, so a board row can say which assistant posted it.
  def self.call(principal_id:, agent_id:, category_slug:, title:, body:, price_text:)
    # Validate the inputs with clean 400s instead of letting find_by!/create!
    # raise a RecordNotFound/RecordInvalid that surfaces as an opaque 500. The
    # error names the valid categories so an assistant that guessed a slug (or
    # omitted it) can recover without fetching the schema first.
    slug  = category_slug.to_s
    valid = Category.order(:slug).pluck(:slug)
    if slug.empty?
      return OperationResult.refused(
        code: "bad_request", message: "category_slug is required — one of: #{valid.join(', ')}",
      )
    end

    category = Category.find_by(slug: slug)
    unless category
      return OperationResult.refused(
        code:    "bad_request",
        message: "unknown category_slug #{slug.inspect} — valid categories: #{valid.join(', ')}",
      )
    end
    if title.to_s.strip.empty? || body.to_s.strip.empty?
      return OperationResult.refused(code: "bad_request", message: "title and body are required")
    end

    # `create!` and NOT `insert!`, which is the opposite of what the sibling
    # demos' INSERTs chose — and the difference is not taste. philslist never
    # wrote this row in raw SQL: `create!` is what the handler has always used,
    # so its validations (`Listing` requires a title and a category) and its
    # timestamps are the published behaviour, and swapping it for `insert!` would
    # change which exception an unrelated bad input raises. A conversion moves
    # code; it does not re-pick the writer.
    listing = Listing.create!(
      owner_id:            principal_id, # a forged owner_id never reaches here
      category:            category,
      title:               title,
      body:                body,
      price_text:          price_text,
      status:              "open",
      created_by_agent_id: agent_id,
    )

    OperationResult.ok({ listing_id: listing.id, status: listing.status })
  end
end
