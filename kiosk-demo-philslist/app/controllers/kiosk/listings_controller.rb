# frozen_string_literal: true

# philslist's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::BoardController — this app's own
# ApplicationController plus `include Kiosk::Action` — because a controller
# declares queries OR actions, never both.
#
# THE THREE WRITES ARE A HANDFUL OF LINES EACH: read the arguments off the
# request, hand them to an Operation, render what it answers (T-083, Phil's
# 2026-08-17 WRITE-OPERATIONS-SEAM decision). That is the fleet's shape, not this
# demo's invention — `post_listing`'s three guards and the two owner-scoped
# UPDATEs are business decisions, and a `render` in the middle of them is what
# every T-057 slice had to reason about. Moving them to app/operations/ is also
# what makes them callable from anywhere: a console, a rake task, a future
# operator back office.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below — an Operation answers with an
# {OperationResult} and {KioskRefusals#render_operation} is the one place that
# becomes a status.
#
# NOT ROUTABLE — see Kiosk::BoardController.
class Kiosk::ListingsController < ApplicationController
  include Kiosk::Action
  include KioskRefusals

  # post_listing — create a listing under the AUTHENTICATED principal. The
  # owner is NOT an input: it is read from the identity the wire resolved, and
  # since 0.4 an agent-supplied `owner_id` does not even reach the handler —
  # `additionalProperties: false` below plus §8.1 item 5's mandatory argument
  # validation refuse it with a typed 400 naming the parameter. (Through 0.3 it
  # was accepted and silently ignored; the description said so, and that
  # sentence is now false, which is why it moved.) The handler guard survives
  # anyway as the second layer — see {PostListingOperation}, where it and
  # created_by_agent_id (the acting agent, for attribution) are written out at
  # length.
  description "Post a new classifieds listing owned by the authenticated principal, open from the " \
              "moment it lands. Ownership is NOT an input: it is taken from the identity the operator " \
              "resolved, and an argument that tries to name a different owner is REFUSED rather than " \
              "quietly ignored. This board carries no money — a price here is display text a human " \
              "reads, never an amount anything can charge against."
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
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
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
  # `Listing.owned_by_current_principal`, i.e. Postgres still evaluates
  # `owner_id = kiosk.current_user_id()` against the transaction GUC; zero rows
  # affected → 403 (answer forbidden, not not-found, so cross-owner probing
  # can't enumerate which ids exist). See {EditListingOperation}.
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
    # An ALLOWLIST, not a loop over caller keys: `permit` is what keeps `status`,
    # `owner_id` and `created_by_agent_id` unwritable from the wire. It stays
    # HERE, in the controller, because it is a method on
    # ActionController::Parameters — the one type on this path an Operation must
    # not have to know about, the same reason getgrocery unwraps `items` at its
    # controller. What crosses the seam is a plain attribute hash. Absent keys
    # arrive ABSENT rather than as nils, which is what preserves "an explicit
    # null clears price_text" as a distinct instruction.
    render_operation EditListingOperation.call(
      listing_id: params[:listing_id],
      changes:    params.permit(:title, :body, :price_text).to_h,
    )
  end

  # close_listing — OWNER-ONLY, same owner-scoped WHERE; zero rows → 403. See
  # {CloseListingOperation}.
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
