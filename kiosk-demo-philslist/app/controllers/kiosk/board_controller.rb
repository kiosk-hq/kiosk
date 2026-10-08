# frozen_string_literal: true

# The read verbs.
class Kiosk::BoardController < ApplicationController
  include Kiosk::Handler

  kind :query
  reach :published
  description "Browse the public classifieds board across ALL sellers — this is the open board, not " \
              "the caller's own corner of it. Filters AND together, so an " \
              "EMPTY array means nothing on the board matched. Sellers are named by an opaque, " \
              "stable pseudonym, never by an " \
              "address — this operator brokers no messages, so the only way to reach a seller is the " \
              "contact details they chose to publish in the listing text. Once the human picks a row, " \
              "`edit_listing` and `close_listing` act on it, and both are owner-only."
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
                    posted_at:     { type: "string", description: "When the listing was published, ISO 8601 carrying YOUR declared zone's offset — `Kiosk-Timezone`, or this board's own clock when you declare none. It is ONE moment, so «newest first» means the same order to every reader." },
                    timezone:      { type: "string", description: "The IANA zone `posted_at` is rendered in: the one you declared, or this board's own when you declared none." },
                    owner_handle:  { type: "string", description: "The seller's PSEUDONYM on this board — stable for one account (so two rows sharing it are the same seller), opaque, and NOT an address: it is derived from the account id and reveals no email, phone or login. There is no verb that turns it back into a person. To reach a seller, use the contact details they chose to put in `body`; a listing with none names no way to contact its seller." },
                  },
                  required: %w[listing_id title body price_text category_slug status posted_at
                               timezone owner_handle],
                }
  example_params({ category_slug: "bikes", keyword: "road" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes", status: "open",
    posted_at: -> { BoardClock.publish(Time.current, BoardClock.default_zone) },
    timezone: BoardClock::DEFAULT_ZONE_NAME,
    owner_handle: "seller-4f2a9c1e3b7d",
  })
  def browse_listings
    board = Listing.open.joins(:category, :owner).order(created_at: :desc, id: :asc)
    board = board.where(categories: { slug: params[:category_slug] }) if params[:category_slug].present?
    if params[:keyword].present?
      pattern = "%#{Listing.sanitize_sql_like(params[:keyword])}%"
      board = board.where(Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern)))
    end

    zone = BoardClock.zone
    render json: board.pluck(
      "listings.id", "listings.title", "listings.body", "listings.price_text",
      "categories.slug", "listings.status", "listings.created_at", "users.id",
    ).map { |id, title, body, price_text, category_slug, row_status, created_at, owner_id|
      { listing_id: id, title: title, body: body, price_text: price_text,
        category_slug: category_slug, status: row_status,
        posted_at: BoardClock.publish(created_at, zone), timezone: zone.name,
        owner_handle: User.public_handle(owner_id) }
    }
  end

  kind :query
  description "List the listings owned by the authenticated principal."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
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
                    posted_at:     { type: "string", description: "When you published it, ISO 8601 carrying YOUR declared zone's offset — `Kiosk-Timezone`, or this board's own clock when you declare none." },
                    timezone:      { type: "string", description: "The IANA zone `posted_at` is rendered in." },
                  },
                  required: %w[listing_id title price_text status category_slug posted_at timezone],
                }
  def my_listings
    zone = BoardClock.zone
    render json: Listing.own
                        .joins(:category)
                        .order(created_at: :desc, id: :asc)
                        .pluck("listings.id", "listings.title", "listings.price_text",
                               "listings.status", "categories.slug", "listings.created_at")
                        .map { |id, title, price_text, row_status, category_slug, created_at|
                          { listing_id: id, title: title, price_text: price_text,
                            status: row_status, category_slug: category_slug,
                            posted_at: BoardClock.publish(created_at, zone), timezone: zone.name }
                        }
  end
end
