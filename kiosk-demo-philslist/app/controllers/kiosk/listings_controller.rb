# frozen_string_literal: true

# philslist's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::BoardController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below.
#
# NOT ROUTABLE — see Kiosk::BoardController.
class Kiosk::ListingsController < ApplicationController
  include Kiosk::Action

  # post_listing — create a listing under the AUTHENTICATED principal. Any
  # agent-supplied owner_id in params is IGNORED (the forged-principal beat):
  # owner_id is read from the identity the wire resolved. created_by_agent_id
  # records the acting agent from the token (attribution).
  #
  # The one asymmetry worth naming: edit/close scope with
  # `Listing.owned_by_current_principal`, which never names the principal in
  # Ruby, while an INSERT has no predicate to hide it in and must supply the
  # value. Both are un-forgeable for the same reason — `kiosk_identity` is read
  # from the Rack env the wire built, which no request argument can write — but
  # only the first keeps the DB as the authority. Moving the column's DEFAULT to
  # `kiosk.current_user_id()` would close the gap; that is a migration, so it is
  # not part of the K-654 handler conversion.
  description "Post a new classifieds listing owned by the authenticated principal. " \
              "price_text is free-form display text (e.g. \"€300\" or \"Free\"), not a " \
              "cents amount. Any owner_id passed in args is ignored — the listing is " \
              "owned by the authenticated principal."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: %w[furniture bikes electronics housing free],
                                  description: "The section to post in (see browse_listings)." },
                 title:         { type: "string", description: "Short headline." },
                 body:          { type: "string", description: "The listing description." },
                 price_text:    { type: "string",
                                  description: "Free-form display price, e.g. \"€300\" or \"Free\"." },
               },
               required: ["category_slug", "title", "body"]
  example_params({
    category_slug: "bikes", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300",
  })
  example_row({ listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", status: "open" })
  def post_listing
    # Validate the inputs with clean 400s instead of letting find_by!/create!
    # raise a RecordNotFound/RecordInvalid that surfaces as an opaque 500. The
    # error names the valid categories so an assistant that guessed a slug (or
    # omitted it) can recover without fetching the schema first.
    slug  = params[:category_slug].to_s
    valid = Category.order(:slug).pluck(:slug)
    return render_bad_request("category_slug is required — one of: #{valid.join(', ')}") if slug.empty?

    category = Category.find_by(slug: slug)
    unless category
      return render_bad_request("unknown category_slug #{slug.inspect} — valid categories: #{valid.join(', ')}")
    end
    if params[:title].to_s.strip.empty? || params[:body].to_s.strip.empty?
      return render_bad_request("title and body are required")
    end

    listing = Listing.create!(
      owner_id:            kiosk_identity.user_id, # forged params[:owner_id] never consulted
      category:            category,
      title:               params[:title],
      body:                params[:body],
      price_text:          params[:price_text],
      status:              "open",
      created_by_agent_id: kiosk_identity.agent_id,
    )

    render json: { listing_id: listing.id, status: listing.status }
  end

  # edit_listing — OWNER-ONLY. The UPDATE is scoped by
  # `Listing.owned_by_current_principal`, i.e. Postgres still evaluates
  # `owner_id = kiosk.current_user_id()` against the transaction GUC; zero rows
  # affected → 403 (answer forbidden, not not-found, so cross-owner probing
  # can't enumerate which ids exist).
  description "Edit one of the authenticated principal's own listings " \
              "(owner-only; editing another owner's listing is forbidden)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 listing_id: { type: "string", format: "uuid",
                               description: "The listing to edit — a `listing_id` from " \
                                            "my_listings or browse_listings, verbatim." },
                 title:      { type: "string", description: "New headline." },
                 body:       { type: "string", description: "New description." },
                 price_text: { type: "string", description: "New display price." },
               },
               required: ["listing_id"]
  def edit_listing
    # K-581/K-582, and the guard got MORE load-bearing when the SQL became
    # ActiveRecord (K-654). It was written because a malformed `listing_id` cast
    # `::uuid` made Postgres raise InvalidTextRepresentation, which is not a
    # Kiosk error and so escaped as a raw 500 leaking "invalid input syntax for
    # type uuid". `where(id:)` does not raise on junk — ActiveRecord's uuid type
    # quietly casts an unparseable value to NULL, which would match no row and
    # answer 403, i.e. a client's typo reported as an ownership refusal. Shape
    # first, then the owner-scoped UPDATE; a well-formed but foreign id still
    # gets the 403, so the shape check never softens the ownership answer.
    return render_malformed_listing_id unless UuidCheck.valid?(params[:listing_id])

    # An allowlist, not a loop over caller keys: `permit` is what keeps
    # `status`, `owner_id` and `created_by_agent_id` unwritable from the wire.
    # `update_all` (not `update!`) is deliberate — it is one statement, so the
    # ownership test and the write cannot be separated by another transaction,
    # and it skips validations exactly as the previous UPDATE did.
    # All three are declared `type: "string"`, so a scalar that arrives as a
    # JSON number or boolean is coerced HERE rather than wherever the
    # persistence layer would do it: ActiveModel's String type renders `true` as
    # Postgres' "t", which is not what a free-form display price should say.
    # nil is preserved as nil — supplying an explicit null is how a caller
    # clears price_text.
    changes = params.permit(:title, :body, :price_text)
                    .to_h
                    .transform_values { |value| value.nil? ? nil : value.to_s }
    # updated_at always bumps, so a patch that supplies nothing still proves
    # ownership through the row count.
    updated = Listing.owned_by_current_principal
                     .where(id: params[:listing_id])
                     .update_all(changes.merge(updated_at: Time.current))

    return render_not_owner("edit") if updated.zero?

    render json: { listing_id: params[:listing_id], updated: true }
  end

  # close_listing — OWNER-ONLY, same owner-scoped WHERE; zero rows → 403.
  description "Close one of the authenticated principal's own listings " \
              "(owner-only; closing another owner's listing is forbidden)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 listing_id: { type: "string", format: "uuid",
                               description: "The listing to close — a `listing_id` from " \
                                            "my_listings or browse_listings, verbatim." },
               },
               required: ["listing_id"]
  def close_listing
    # K-581/K-582: same guard as edit_listing, for the same reason — malformed
    # shape answers 400; a well-formed foreign id still answers 403.
    return render_malformed_listing_id unless UuidCheck.valid?(params[:listing_id])

    updated = Listing.owned_by_current_principal
                     .where(id: params[:listing_id])
                     .update_all(status: "closed", updated_at: Time.current)

    return render_not_owner("close") if updated.zero?

    render json: { listing_id: params[:listing_id], status: "closed" }
  end

  private

  # The three refusals below are the whole error surface of this controller, and
  # each is a plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply these two, but writing it keeps the answer explicit.
  def render_bad_request(message, hint: nil)
    render json: { error: { code: "bad_request", message: message, hint: hint }.compact },
           status: :bad_request
  end

  def render_malformed_listing_id
    render_bad_request("listing_id #{params[:listing_id].to_s.inspect} is not a uuid",
                hint: "Pass a `listing_id` from my_listings / browse_listings, verbatim.")
  end

  def render_not_owner(verb)
    render json: { error: { code:    "forbidden",
                            message: "listing not owned by the authenticated principal",
                            hint:    "You may only #{verb} your own listings." } },
           status: :forbidden
  end
end
