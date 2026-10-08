# frozen_string_literal: true

# Posts an open listing owned by the principal the wire resolved.
class PostListingOperation
  def self.call(principal_id:, agent_id:, category_slug:, title:, body:, price_text:)
    if title.strip.empty? || body.strip.empty?
      raise Kiosk::Server::Errors::BadRequest, "title and body are required"
    end

    listing = Listing.create!(
      owner_id:            principal_id,
      category:            Category.find_by!(slug: category_slug),
      title:               title,
      body:                body,
      price_text:          price_text,
      created_by_agent_id: agent_id,
    )

    { listing_id: listing.id, status: listing.status }
  end
end
