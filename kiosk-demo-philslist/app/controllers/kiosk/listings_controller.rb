# frozen_string_literal: true

# philslist's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/<action-name>` — same shape as Kiosk::BoardController, `kind
# :action` above each declaration. NOT ROUTABLE, see that controller.
#
# Each write reads its arguments off the request, hands them to an Operation and
# renders what it answers (T-083); the business decisions live in
# app/operations/, callable from a console or a rake task as well as the wire.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code. {KioskRefusals#render_operation} is
# the one place an {OperationResult} becomes a status.
class Kiosk::ListingsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # post_listing — create a listing under the AUTHENTICATED principal. The owner
  # is NOT an input: it is read from the identity the wire resolved, and an
  # agent-supplied `owner_id` never reaches the handler — `additionalProperties:
  # false` below plus §8.1 item 5's mandatory argument validation refuse it with
  # a typed 400 naming the parameter. {PostListingOperation} is the second layer.
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
                 # THE `categories` TABLE, not a copy of it (K-922) — same proc
                 # and same reason as `browse_listings`.
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "The section to post in (see browse_listings)." },
                 title:         { type: "string", description: "Short headline." },
                 # THE ONLY CONTACT CHANNEL THIS BOARD HAS (K-913): sellers are
                 # pseudonymous and there is no relayed-message verb, so the
                 # contact line is the human's choice and the human's words.
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
    render_operation PostListingOperation.call(
      principal_id:  kiosk_identity.user_id, # forged params[:owner_id] never consulted
      agent_id:      kiosk_identity.agent_id,
      category_slug: params[:category_slug],
      title:         params[:title],
      body:          params[:body],
      price_text:    params[:price_text],
    )
  end

  # edit_listing — OWNER-ONLY. The UPDATE is scoped by
  # `Listing.owned_by_current_principal`, so Postgres evaluates
  # `owner_id = kiosk.current_user_id()` against the transaction GUC; zero rows
  # affected → 403, not 404, so ids cannot be enumerated. See {EditListingOperation}.
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
                 price_text: { type: "string", description: "New display price." },
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
    # An ALLOWLIST, not a loop over caller keys: `permit` keeps `status`,
    # `owner_id` and `created_by_agent_id` unwritable from the wire. Absent keys
    # arrive ABSENT rather than as nils — that is what keeps "an explicit null
    # clears price_text" a distinct instruction.
    render_operation EditListingOperation.call(
      listing_id: params[:listing_id],
      changes:    params.permit(:title, :body, :price_text).to_h,
    )
  end

  # close_listing — OWNER-ONLY, same owner-scoped WHERE; zero rows → 403. See
  # {CloseListingOperation}.
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
    render_operation CloseListingOperation.call(listing_id: params[:listing_id])
  end
end
