# frozen_string_literal: true

# philslist's READ surface: the two verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::ListingsController.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::BoardController < ApplicationController
  include Kiosk::Query

  # browse_listings — the OPEN board. Any authenticated principal sees ALL
  # matching listings across ALL owners (no owner_id filter). Optional
  # category_slug + keyword filters; status clamps to open|closed (defaults
  # open). No caller value is ever spliced into SQL: the filters are ordinary
  # ActiveRecord conditions and the keyword search is an Arel `matches` (which
  # is Postgres ILIKE), so the escaping is the adapter's job, not the handler's
  # (K-654).
  description "Browse the public classifieds board across all sellers. Optional " \
              "category_slug and keyword filters; status defaults to open. All " \
              "filters are optional and AND together; each row carries a " \
              "`listing_id` (pass it to edit_listing / close_listing as `listing_id`), " \
              "title, body, free-form price_text, category_slug, status, and " \
              "owner_handle. Returns all matching listings (small board; not " \
              "paginated); prices are free-form text (e.g. \"€300\"), not cents."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: %w[furniture bikes electronics housing free],
                                  description: "Restrict to one category." },
                 keyword:       { type: "string", description: "Case-insensitive match on title or body." },
                 status:        { type: "string", enum: %w[open closed], default: "open",
                                  description: "Listing status filter." },
               },
               required: []
  output_schema type: "array",
                description: "Matching listings across all sellers, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "uuid. Pass to edit_listing / close_listing as `listing_id`." },
                    title:         { type: "string", description: "The seller's headline." },
                    body:          { type: "string", description: "The listing description." },
                    price_text:    { type: %w[string null], description: "FREE-FORM display text, e.g. \"€300\" or \"Free\" — never a cents amount, and null when the seller gave none." },
                    category_slug: { type: "string", description: "The section it is posted in." },
                    status:        { type: "string", description: "open | closed." },
                    owner_handle:  { type: "string", description: "The seller's handle." },
                  },
                  required: %w[listing_id title body price_text category_slug status owner_handle],
                }
  example_params({ category_slug: "bikes", keyword: "road", status: "open" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes", status: "open",
    owner_handle: "alice@example.com",
  })
  def browse_listings
    status = params[:status].to_s
    status = "open" unless Listing::STATUSES.include?(status)

    board = Listing.joins(:category, :owner)
                   .where(status: status)
                   .order(created_at: :desc, id: :asc)
    board = board.where(categories: { slug: params[:category_slug].to_s }) if params[:category_slug].present?
    if params[:keyword].present?
      pattern = "%#{params[:keyword]}%"
      board = board.where(
        Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern)),
      )
    end

    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names and their order a decision
    # this handler makes rather than a side effect of the schema. One query, no
    # N+1 — the joins above already carry the category slug and the owner handle.
    render json: board.pluck(
      "listings.id", "listings.title", "listings.body", "listings.price_text",
      "categories.slug", "listings.status", "users.email",
    ).map { |id, title, body, price_text, category_slug, row_status, owner_handle|
      { listing_id: id, title: title, body: body, price_text: price_text,
        category_slug: category_slug, status: row_status, owner_handle: owner_handle }
    }
  end

  # my_listings — per-identity: the caller's OWN listings only. Caller supplies
  # no filter; the scope is provider-controlled and un-bypassable (the saas
  # my_appointments pattern). `owned_by_current_principal` is the ONE place the
  # identity predicate is written — see Listing for why it stays SQL-side.
  description "List the listings owned by the authenticated principal " \
              "(scoped to kiosk.current_user_id())."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # NARROWER than a browse_listings row on purpose: an owner reading their own
  # board does not need the body or their own handle back, so this projection
  # is four fields rather than seven and the schema is where an assistant reads
  # that difference instead of discovering it.
  output_schema type: "array",
                description: "The principal's own listings, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "uuid. Pass to edit_listing / close_listing as `listing_id`." },
                    title:         { type: "string", description: "The headline." },
                    price_text:    { type: %w[string null], description: "FREE-FORM display text, never a cents amount; null when none was given." },
                    status:        { type: "string", description: "open | closed." },
                    category_slug: { type: "string", description: "The section it is posted in." },
                  },
                  required: %w[listing_id title price_text status category_slug],
                }
  def my_listings
    render json: Listing.owned_by_current_principal
                        .joins(:category)
                        .order(created_at: :desc, id: :asc)
                        .pluck("listings.id", "listings.title", "listings.price_text",
                               "listings.status", "categories.slug")
                        .map { |id, title, price_text, row_status, category_slug|
                          { listing_id: id, title: title, price_text: price_text,
                            status: row_status, category_slug: category_slug }
                        }
  end
end
