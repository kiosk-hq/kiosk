# frozen_string_literal: true

# post_listing — create a classifieds listing owned by the AUTHENTICATED
# principal, in the section the caller named. Wire-only today: philslist's
# public board is read-only and nothing on the human surface posts.
class PostListingOperation
  # @param principal_id [String] the account the wire resolved — NEVER an
  #   argument off the request, which is what lets `post_listing` ignore a forged
  #   `owner_id` in the body. An INSERT is the one place the principal must be
  #   spelled in Ruby: the owner-scoped verbs next door hide it inside a WHERE
  #   predicate (`Listing.owned_by_current_principal`), an INSERT has none. Both
  #   are un-forgeable — the identity comes from the Rack env the wire built —
  #   but only the WHERE keeps the database as the authority; a column DEFAULT
  #   of `kiosk.current_user_id()` would close that gap.
  # @param agent_id [String, nil] the ACTING agent (kiosk.agents.id) —
  #   attribution, so a board row can say which assistant posted it.
  def self.call(principal_id:, agent_id:, category_slug:, title:, body:, price_text:)
    # Validate with clean 400s instead of letting find_by!/create! raise a
    # RecordNotFound/RecordInvalid that surfaces as an opaque 500. The error
    # names the valid categories, so a wrong guess recovers without the schema.
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

    # `create!`, not the `insert!` the sibling demos use: `Listing`'s validations
    # and its timestamps are this row's published behaviour, and `insert!` would
    # change which exception a bad input raises.
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
