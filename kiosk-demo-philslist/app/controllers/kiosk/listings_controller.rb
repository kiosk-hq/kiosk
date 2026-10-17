# frozen_string_literal: true

# Classified listings: the public board and each seller's own.
class Kiosk::ListingsController < ApplicationController
  include Kiosk::Handler

  PRICE_TEXT = { type: %w[string null], description: "Display price, e.g. \"€300\" or \"Free\"; null when none." }.freeze

  kind :query
  reach :published
  description "Search the open board across all sellers. To contact a seller, use the contact details in the listing text."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "Restrict to one category." },
                 keyword:       { type: "string", description: "Matches title or body, case-insensitive." },
               },
               required: []
  output_schema type: "array",
                description: "Open listings, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "Pass to edit_listing or close_listing." },
                    title:         { type: "string", description: "The seller's headline." },
                    body:          { type: "string", description: "The listing text, with the seller's contact details if they gave any." },
                    price_text:    PRICE_TEXT,
                    category_slug: { type: "string", description: "The listing's category." },
                    posted_at:     { type: "string", description: "When it was posted, in your `Kiosk-Timezone` or the board's own zone." },
                    timezone:      { type: "string", description: "The IANA zone of `posted_at`." },
                    owner_handle:  { type: "string", description: "A name for the seller, the same on all their listings. It does not reveal who they are." },
                  },
                  required: %w[listing_id title body price_text category_slug posted_at timezone owner_handle],
                }
  example_params({ category_slug: "bikes", keyword: "road" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes",
    posted_at: -> { BoardClock.publish(Time.current, BoardClock.default_zone) },
    timezone: BoardClock::DEFAULT_ZONE_NAME,
    owner_handle: "seller-4f2a9c1e3b7d",
  })
  def browse_listings
    board = Listing.open.joins(:category, :owner).includes(:category).order(created_at: :desc, id: :asc)
    board = board.where(categories: { slug: params[:category_slug] }) if params[:category_slug].present?
    if params[:keyword].present?
      pattern = "%#{Listing.sanitize_sql_like(params[:keyword])}%"
      board = board.where(Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern)))
    end
    @listings = board
  end

  kind :query
  description "The signed-in seller's own listings, open and closed."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "Newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "Pass to edit_listing or close_listing." },
                    title:         { type: "string", description: "The headline." },
                    price_text:    PRICE_TEXT,
                    status:        { type: "string", enum: Listing.statuses.values, description: "Whether it is on the board." },
                    category_slug: { type: "string", description: "The listing's category." },
                    posted_at:     { type: "string", description: "When it was posted, in your `Kiosk-Timezone` or the board's own zone." },
                    timezone:      { type: "string", description: "The IANA zone of `posted_at`." },
                  },
                  required: %w[listing_id title price_text status category_slug posted_at timezone],
                }
  def my_listings
    @listings = Listing.own.includes(:category).order(created_at: :desc, id: :asc)
  end

  kind :action
  description "Post a listing for the signed-in seller. It is on the board at once."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "The section to post in." },
                 title:         { type: "string", description: "Short headline." },
                 body:          { type: "string",
                                  description: "The listing text, public to everyone. Buyers can contact the seller only " \
                                               "through it, so ask the seller how they want to be contacted and include that." },
                 price_text:    { type: "string", description: "Display price, e.g. \"€300\" or \"Free\"." },
               },
               required: ["category_slug", "title", "body"]
  output_schema type: "object",
                description: "The posted listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "Pass to edit_listing or close_listing." },
                  status:     { const: "open", description: "A new listing is open." },
                },
                required: %w[listing_id status]
  example_params({
    category_slug: "bikes", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset. Text 555-0100 to arrange a viewing.",
    price_text: "€300",
  })
  example_row({ listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", status: "open" })
  def post_listing
    @listing = PostListingOperation.call(
      seller_id:     kiosk_identity.user_id,
      agent_id:      kiosk_identity.agent_id,
      category_slug: params[:category_slug],
      title:         params[:title],
      body:          params[:body],
      price_text:    params[:price_text],
    )
  end

  kind :action
  description "Change one of the signed-in seller's listings. Omitted fields stay as they are."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 listing_id: { type: "string", format: "uuid", description: "From my_listings or browse_listings." },
                 title:      { type: "string", description: "New headline." },
                 body:       { type: "string", description: "New listing text." },
                 price_text: { type: %w[string null], description: "New display price, or `null` to clear it." },
               },
               required: ["listing_id"]
  output_schema type: "object",
                description: "The edited listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "The edited listing." },
                  updated:    { const: true, description: "The edit is saved." },
                },
                required: %w[listing_id updated]
  def edit_listing
    @listing = EditListingOperation.call(
      listing_id: params[:listing_id],
      changes:    params.permit(:title, :body, :price_text).to_h,
    )
  end

  kind :action
  description "Take one of the signed-in seller's listings off the board."
  input_schema type: "object",
               additionalProperties: false,
               properties: { listing_id: { type: "string", format: "uuid", description: "From my_listings or browse_listings." } },
               required: ["listing_id"]
  output_schema type: "object",
                description: "The closed listing.",
                additionalProperties: false,
                properties: {
                  listing_id: { type: "string", description: "The closed listing." },
                  status:     { const: "closed", description: "The listing is closed." },
                },
                required: %w[listing_id status]
  def close_listing
    @listing = CloseListingOperation.call(listing_id: params[:listing_id])
  end
end
