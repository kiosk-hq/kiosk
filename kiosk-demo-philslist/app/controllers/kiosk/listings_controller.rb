# frozen_string_literal: true

# Each seller's own classified listings: posting, editing and closing them.
module Kiosk
  class ListingsController < ActionController::API
    include Kiosk::Handler

    PRICE_TEXT = { type: %w[string null], description: 'Display price, e.g. "€300" or "Free"; null when none.' }.freeze

    kind :query
    description "The signed-in seller's own listings, open and closed."
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'Newest first.',
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      listing_id: { type: 'string', description: 'Pass to edit_listing or close_listing.' },
                      title: { type: 'string', description: 'The headline.' },
                      price_text: PRICE_TEXT,
                      status: { type: 'string', enum: Listing.statuses.values, description: 'Whether it is on the board.' },
                      category_slug: { type: 'string', description: "The listing's category." },
                      posted_at: { type: 'string', description: "When it was posted, in your `Kiosk-Timezone` or the board's own zone." },
                      timezone: { type: 'string', description: 'The IANA zone of `posted_at`.' }
                    },
                    required: %w[listing_id title price_text status category_slug posted_at timezone]
                  }
    def my_listings
      @listings = Listing.own.includes(:category).order(created_at: :desc, id: :asc)
    end

    kind :action
    description 'Post a listing for the signed-in seller. It is on the board at once.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   category_slug: { type: 'string',
                                    enum: -> { Category.order(:slug).pluck(:slug) },
                                    description: 'The section to post in.' },
                   title: { type: 'string', description: 'Short headline.' },
                   body: { type: 'string',
                           description: 'The listing text, public to everyone. Buyers can contact the seller only ' \
                                        'through it, so ask the seller how they want to be contacted and include that.' },
                   price_text: { type: 'string', description: 'Display price, e.g. "€300" or "Free".' }
                 },
                 required: %w[category_slug title body]
    output_schema type: 'object',
                  description: 'The posted listing.',
                  additionalProperties: false,
                  properties: {
                    listing_id: { type: 'string', description: 'Pass to edit_listing or close_listing.' },
                    status: { const: 'open', description: 'A new listing is open.' }
                  },
                  required: %w[listing_id status]
    example_params({
                     category_slug: 'bikes', title: 'Carbon road bike — €300',
                     body: 'Lightweight carbon road bike, 54cm, Shimano 105 groupset. Text 555-0100 to arrange a viewing.',
                     price_text: '€300'
                   })
    example_row({ listing_id: '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f', status: 'open' })
    def post_listing
      @listing = PostListingOperation.call(seller: kiosk_identity, category_slug: params[:category_slug],
                                           title: params[:title], body: params[:body], price_text: params[:price_text])
    end

    kind :action
    description "Change one of the signed-in seller's listings. Omitted fields stay as they are."
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   listing_id: { type: 'string', format: 'uuid', description: 'From my_listings or browse_listings.' },
                   title: { type: 'string', description: 'New headline.' },
                   body: { type: 'string', description: 'New listing text.' },
                   price_text: { type: %w[string null], description: 'New display price, or `null` to clear it.' }
                 },
                 required: ['listing_id']
    output_schema type: 'object',
                  description: 'The edited listing.',
                  additionalProperties: false,
                  properties: {
                    listing_id: { type: 'string', description: 'The edited listing.' },
                    updated: { const: true, description: 'The edit is saved.' }
                  },
                  required: %w[listing_id updated]
    def edit_listing
      @listing = EditListingOperation.call(
        listing_id: params[:listing_id],
        changes: params.permit(:title, :body, :price_text).to_h
      )
    end

    kind :action
    description "Take one of the signed-in seller's listings off the board."
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: { listing_id: { type: 'string', format: 'uuid', description: 'From my_listings or browse_listings.' } },
                 required: ['listing_id']
    output_schema type: 'object',
                  description: 'The closed listing.',
                  additionalProperties: false,
                  properties: {
                    listing_id: { type: 'string', description: 'The closed listing.' },
                    status: { const: 'closed', description: 'The listing is closed.' }
                  },
                  required: %w[listing_id status]
    def close_listing
      @listing = CloseListingOperation.call(listing_id: params[:listing_id])
    end
  end
end
