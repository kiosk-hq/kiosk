# frozen_string_literal: true

# philslist's READ surface: the two verbs an assistant reaches with
# `GET /kiosk/<query-name>`. `include Kiosk::Handler` is the whole contract —
# each class-level macro records a declaration and the NEXT `def` claims it, so
# a method with no macros above it is a helper the wire cannot see. `kind` is
# what puts a declaration on `GET` or `POST`, and it belongs to the DECLARATION,
# not to the class (K-921) — the write half simply lives next door.
#
# NOT ROUTABLE: config/routes.rb draws nothing here. Authentication, the
# registration PoW gate and the GUC-scoped transaction all live in the wire, so
# a route drawn straight at a handler would bypass all three — the mixin 404s.
class Kiosk::BoardController < ApplicationController
  include Kiosk::Handler

  # browse_listings — the OPEN board. Any authenticated principal sees ALL
  # matching listings across ALL owners; `category_slug` and `keyword` are the
  # two optional filters. There is deliberately no `status` filter (Phil,
  # 2026-08-21): this verb IS the open board, so a status knob could only ask
  # for rows it does not serve. "Did my listing sell?" is `my_listings`.
  #
  # No SQL is built by hand: the filters are ordinary ActiveRecord conditions
  # and the keyword search an Arel node, so caller values are adapter-quoted
  # (K-654) — inlined rather than bound, since Rails 8.1 disables prepared
  # statements by default. Quoting does NOT neutralise LIKE metacharacters,
  # which is what `sanitize_sql_like` below is for (K-914).
  #
  # `reach :published` (K-949, ADR-0028) declares the departure from spec §7.2,
  # whose default is that a verb touches only the calling principal's rows — an
  # open board showing you only your own listings would not be a board. It is
  # `published`, not `consented`: nobody consented, philslist publishes by its
  # own decision. §7.2 forbids a login identifier anywhere in a published row,
  # which is why `owner_handle` is a pseudonym (K-913).
  kind :query
  reach :published
  description "Browse the public classifieds board across ALL sellers — this is the open board, not " \
              "the caller's own corner of it. Every filter is optional and they AND together, so an " \
              "EMPTY array means nothing on the board matched. Sellers are named by an opaque, " \
              "stable pseudonym, never by an " \
              "address — this operator brokers no messages, so the only way to reach a seller is the " \
              "contact details they chose to publish in the listing text. Once the human picks a row, " \
              "`edit_listing` and `close_listing` act on it, and both are owner-only."
  # `category_slug`'s domain IS THE `categories` TABLE, so it is a PROC, not a
  # literal list (K-922): the engine calls it when the catalog is served and
  # `schema_url`'s `?v=` moves with it, so adding a section needs no redeploy.
  # An inline `Category.pluck(:slug)` would run at class-body load instead —
  # `db:create` included. Ordered, so the published enum is byte-stable.
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "Restrict to one category." },
                 keyword:       { type: "string", description: "Case-insensitive match on title or body." },
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
                    status:        { type: "string", description: "Always `open` on this verb — the board carries open listings only." },
                    # `string`, flatly (K-913): the handle is
                    # {User.public_handle}, derived from the account UUID, and
                    # an account without a UUID cannot own a row.
                    owner_handle:  { type: "string", description: "The seller's PSEUDONYM on this board — stable for one account (so two rows sharing it are the same seller), opaque, and NOT an address: it is derived from the account id and reveals no email, phone or login. There is no verb that turns it back into a person. To reach a seller, use the contact details they chose to put in `body`; a listing with none names no way to contact its seller." },
                  },
                  required: %w[listing_id title body price_text category_slug status owner_handle],
                }
  example_params({ category_slug: "bikes", keyword: "road" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes", status: "open",
    owner_handle: "seller-4f2a9c1e3b7d",
  })
  def browse_listings
    # `status: "open"` is the board, not a default the caller may override —
    # there is no `status` parameter. An out-of-domain `category_slug` never
    # reaches here either: its enum is validated on every per-verb call (spec
    # §8.1 item 5), so an unknown section is answered 400 naming the live ones.
    board = Listing.joins(:category, :owner)
                   .where(status: "open")
                   .order(created_at: :desc, id: :asc)
    board = board.where(categories: { slug: params[:category_slug].to_s }) if params[:category_slug].present?
    if params[:keyword].present?
      # `sanitize_sql_like` FIRST, the surrounding `%` after it (K-914). Adapter
      # quoting keeps the value inside the literal but does nothing about LIKE's
      # own metacharacters: an unescaped `_` or `%` would be a live wildcard.
      pattern = "%#{Listing.sanitize_sql_like(params[:keyword])}%"
      board = board.where(
        Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern)),
      )
    end

    # A projection, not model loading: naming the columns keeps the wire's field
    # names and their order this handler's decision, in one query.
    #
    # `users.id`, NEVER `users.email` (K-913): this column is published to every
    # principal that can authenticate, and the id does not reach the wire either
    # — {User.public_handle} turns it into the board pseudonym first. The join
    # stays because a listing whose owner vanished should fall off the board.
    render json: board.pluck(
      "listings.id", "listings.title", "listings.body", "listings.price_text",
      "categories.slug", "listings.status", "users.id",
    ).map { |id, title, body, price_text, category_slug, row_status, owner_id|
      { listing_id: id, title: title, body: body, price_text: price_text,
        category_slug: category_slug, status: row_status,
        owner_handle: User.public_handle(owner_id) }
    }
  end

  # my_listings — per-identity: the caller's OWN listings only, with no filter
  # to supply. `owned_by_current_principal` is the ONE place the identity
  # predicate is written; see Listing for why it stays SQL-side.
  kind :query
  description "List the listings owned by the authenticated principal " \
              "(scoped to kiosk.current_user_id())."
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # NARROWER than a browse_listings row on purpose: an owner reading their own
  # board needs neither the body nor their own handle back, so the schema is
  # where an assistant reads that difference instead of discovering it.
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
