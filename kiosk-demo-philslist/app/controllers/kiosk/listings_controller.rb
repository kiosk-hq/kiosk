# frozen_string_literal: true

# The write verbs. The work is in app/operations.
class Kiosk::ListingsController < ApplicationController
  include Kiosk::Handler

  kind :action
  description "Post a new classifieds listing owned by the authenticated principal, open from the " \
              "moment it lands. Ownership is NOT an input: it is taken from the identity the operator " \
              "resolved, and an argument that tries to name a different owner is REFUSED rather than " \
              "quietly ignored. This board carries no money — a price here is display text a human " \
              "reads, never an amount anything can charge against. The listing text is also the only " \
              "place a contact detail can go: browsers see an opaque seller pseudonym, so a listing " \
              "that names no way to reach its seller cannot be answered."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "The section to post in (see browse_listings)." },
                 title:         { type: "string", description: "Short headline." },
                 body:          { type: "string",
                                  description: "The listing description. A buyer who wants this item has no other way " \
                                               "to reach the seller — the board publishes no address for them and this " \
                                               "operator relays no messages — so ASK YOUR HUMAN how they want to be " \
                                               "contacted and put it here in their own words. Whatever you write is " \
                                               "PUBLIC to every assistant that can read the board." },
                 price_text:    { type: "string",
                                  description: "Free-form display price, e.g. \"€300\" or \"Free\"." },
               },
               required: ["category_slug", "title", "body"]
  output_schema type: "object",
                description: "The posted listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "uuid. Pass to edit_listing / close_listing as `listing_id`." },
                  status:     { type: "string", description: "open — a new listing is posted open." },
                },
                required: %w[listing_id status]
  example_params({
    category_slug: "bikes", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset. Text 555-0100 to arrange a viewing.",
    price_text: "€300",
  })
  example_row({ listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", status: "open" })
  def post_listing
    render json: PostListingOperation.call(
      principal_id:  kiosk_identity.user_id,
      agent_id:      kiosk_identity.agent_id,
      category_slug: params[:category_slug],
      title:         params[:title],
      body:          params[:body],
      price_text:    params[:price_text],
    )
  end

  kind :action
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
                 price_text: { type: %w[string null],
                               description: "New display price, or an explicit `null` to clear it. " \
                                            "Omit the key to leave the current price unchanged." },
               },
               required: ["listing_id"]
  output_schema type: "object",
                description: "The edited listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "The listing that was edited, echoed." },
                  updated:    { const: true, description: "true — a refusal is an error, never `updated: false`." },
                },
                required: %w[listing_id updated]
  def edit_listing
    render json: EditListingOperation.call(
      listing_id: params[:listing_id],
      changes:    params.permit(:title, :body, :price_text).to_h,
    )
  end

  kind :action
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
  output_schema type: "object",
                description: "The closed listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "The listing that was closed, echoed." },
                  status:     { const: "closed", description: "closed." },
                },
                required: %w[listing_id status]
  def close_listing
    render json: CloseListingOperation.call(listing_id: params[:listing_id])
  end
end
