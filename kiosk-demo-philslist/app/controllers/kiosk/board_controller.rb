# frozen_string_literal: true

# The public board of open classified listings, across all sellers.
module Kiosk
  class BoardController < ActionController::API
    include Kiosk::Handler

    kind :query
    reach :published
    description 'Search the open board across all sellers. To contact a seller, use the contact details in the listing text.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   category_slug: { type: 'string',
                                    enum: -> { Category.order(:slug).pluck(:slug) },
                                    description: 'Restrict to one category.' },
                   keyword: { type: 'string', description: 'Matches title or body, case-insensitive.' }
                 },
                 required: []
    output_schema type: 'array',
                  description: 'Open listings, newest first.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      listing_id: { type: 'string', description: 'Pass to edit_listing or close_listing.' },
                      title: { type: 'string', description: "The seller's headline." },
                      body: { type: 'string', description: "The listing text, with the seller's contact details if they gave any." },
                      price_text: ListingsController::PRICE_TEXT,
                      category_slug: { type: 'string', description: "The listing's category." },
                      posted_at: { type: 'string', description: "When it was posted, in your `Kiosk-Timezone` or the board's own zone." },
                      timezone: { type: 'string', description: 'The IANA zone of `posted_at`.' },
                      owner_handle: { type: 'string', description: 'A name for the seller, the same on all their listings. It does not reveal who they are.' }
                    },
                    required: %w[listing_id title body price_text category_slug posted_at timezone owner_handle]
                  }
    example_params({ category_slug: 'bikes', keyword: 'road' })
    example_row({
                  listing_id: '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f', title: 'Carbon road bike — €300',
                  body: 'Lightweight carbon road bike, 54cm, Shimano 105 groupset.',
                  price_text: '€300', category_slug: 'bikes',
                  posted_at: -> { BoardClock.publish(Time.current, BoardClock.default_zone) },
                  timezone: BoardClock::DEFAULT_ZONE_NAME,
                  owner_handle: 'seller-4f2a9c1e3b7d'
                })
    def browse_listings
      board = open_board
      board = board.where(categories: { slug: params[:category_slug] }) if params[:category_slug].present?
      @listings = params[:keyword].present? ? board.where(keyword_match(params[:keyword])) : board
    end

    private

    def open_board = Listing.open.joins(:category, :owner).includes(:category).order(created_at: :desc, id: :asc)

    # Title or body contains the keyword, case-insensitively.
    def keyword_match(keyword)
      pattern = "%#{Listing.sanitize_sql_like(keyword)}%"
      Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern))
    end
  end
end
